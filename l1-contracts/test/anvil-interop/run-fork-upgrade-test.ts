#!/usr/bin/env node

/**
 * Fork-mode v31 Upgrade Test.
 *
 * Validates the v31 ecosystem upgrade against a forked real L1 and two forked L2
 * zkOS chains, by:
 *   1. Forking an upstream L1 RPC via anvil (--fork-url).
 *   2. Forking up to two L2 zkOS chains via anvil against their real RPCs.
 *   3. Resolving bridgehub / governance / CTM addresses from the live forked state.
 *   4. Running the shared `v31-upgrade-test-runner` helpers: ecosystem upgrade scripts,
 *      governance stage 0/1/2 execution, per-chain `ChainUpgrade_v31` + L2 relay
 *      (with force-deploy-driven anvil_setCode overrides), stage3 migration,
 *      protocol-version verification.
 *
 * Unlike `run-v30-to-v31-upgrade-test.ts`, this does NOT load pre-generated chain states
 * and does NOT perform the synthetic-state setup steps (ownership transfer, ChainAdmin
 * deploy, v30 storage patches) — real forked state already has all of those.
 *
 * Required env vars:
 *   L1_FORK_URL         — RPC of the L1 to fork (sepolia, mainnet, stage, local)
 *   BRIDGEHUB_ADDRESS   — L1 Bridgehub proxy address on the forked L1
 *
 * Optional env vars:
 *   L1_FORK_BLOCK                     — pin L1 fork to a specific block
 *   FORK_CHAIN_IDS                    — comma-separated chain IDs to test (e.g. "270,271")
 *   FORK_PERMANENT_VALUES_PATH        — permanent-values template, relative to l1-contracts
 *                                        (default: upgrade-envs/permanent-values/local.toml)
 *   FORK_UPGRADE_INPUT_PATH           — upgrade-input template, relative to l1-contracts
 *                                        (default: upgrade-envs/v0.30.0-zksync-os-blobs/localhost.toml)
 *   L2_FORK_URL_<chainId>             — per-chain L2 RPC override
 *
 * Per-chain L2 RPCs can also live in `config/fork-l2-rpcs.json` (gitignored):
 *   { "270": "https://mainnet.era.zksync.io", "271": "https://rpc.chain271.xyz" }
 */

import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { AnvilManager } from "./src/daemons/anvil-manager";
import { runForgeScript } from "./src/core/forge";
import { getAbi } from "./src/core/contracts";
import { ANVIL_DEFAULT_ACCOUNT_ADDR } from "./src/core/const";
import { runtimeConfig } from "./src/core/runtime-config";
import { loadForkConfig } from "./src/core/fork-config";
import { discoverForkChains } from "./src/deployers/fork-chain-discovery";
import {
  decodeGovernanceCalls,
  executeGovernanceCalls,
  prepareUpgradeHarnessInputs,
  readEcosystemOutput,
  readNestedString,
  runChainUpgradesAndRelayL2,
  runChainUpgradesPerCtm,
  runEcosystemUpgradeScripts,
  runEcosystemUpgradeScriptsForEnv,
  verifyProtocolVersions,
} from "./src/helpers/v31-upgrade-test-runner";
import type { V31UpgradeScenario } from "./src/helpers/v31-upgrade-test-runner";
import { advanceL1TimePastUpgradeDeadline } from "./src/helpers/harness-shims";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");
const totalStart = Date.now();

function elapsed(): string {
  return `${((Date.now() - totalStart) / 1000).toFixed(1)}s`;
}

/** Deterministic port allocation for fork-mode to avoid clashing with the default harness ports. */
function allocatePort(offset: number): number {
  return 19545 + offset;
}

/**
 * L1-only chain discovery: skips the L2 RPC requirement of `discoverForkChains`.
 * Used when `FORK_SKIP_L2=1` so the harness can still resolve diamond proxies
 * + chain admins for prepare/governance/stage3 testing without spinning L2
 * forks. Returns objects with `l2RpcUrl: ""` to keep the shape compatible.
 */
async function discoverForkChainsL1Only(
  l1Provider: ethers.providers.JsonRpcProvider,
  cfg: { bridgehubAddress: string; chainIdFilter: number[] }
): Promise<Array<{ chainId: number; diamondProxy: string; chainAdmin: string; l2RpcUrl: string }>> {
  const bridgehub = new ethers.Contract(cfg.bridgehubAddress, getAbi("L1Bridgehub"), l1Provider);
  const rawIds: ethers.BigNumber[] = await bridgehub.getAllZKChainChainIDs();
  const allChainIds = rawIds.map((n) => n.toNumber());
  const selected = cfg.chainIdFilter.length > 0 ? cfg.chainIdFilter : allChainIds.slice(0, 2);
  const adminAbi = getAbi("GettersFacet");
  const out = [];
  for (const chainId of selected) {
    const diamondProxy: string = await bridgehub.getZKChain(chainId);
    if (!diamondProxy || diamondProxy === ethers.constants.AddressZero) {
      throw new Error(`Chain ${chainId}: not registered on bridgehub`);
    }
    const getters = new ethers.Contract(diamondProxy, adminAbi, l1Provider);
    const chainAdmin: string = await getters.getAdmin();
    out.push({ chainId, diamondProxy, chainAdmin, l2RpcUrl: "" });
  }
  return out;
}

/**
 * Read the governance-owner address and CTM address from the forked L1 state.
 *
 * On decentralized-governance stage/mainnet ecosystems, `bridgehub.owner()` returns the
 * ProtocolUpgradeHandler proxy (not a simple Ownable2Step `Governance.sol`). That contract
 * has no `.owner()` getter — protocol-ops' two-level Ownable resolution (`upgrade-governance`)
 * therefore fails. In fork mode we bypass that and impersonate the returned address directly,
 * since `anvil --auto-impersonate` lets any address send txs.
 *
 * The CTM is the one registered for the first test chain (all selected chains share the
 * same CTM on mainnet/stage zkOS ecosystems).
 */
async function resolveL1Addresses(
  l1Provider: ethers.providers.JsonRpcProvider,
  bridgehubAddress: string,
  firstChainId: number
): Promise<{ governance: string; chainTypeManager: string }> {
  const bridgehub = new ethers.Contract(bridgehubAddress, getAbi("L1Bridgehub"), l1Provider);
  const governance: string = await bridgehub.owner();
  const chainTypeManager: string = await bridgehub.chainTypeManager(firstChainId);
  if (!chainTypeManager || chainTypeManager === ethers.constants.AddressZero) {
    throw new Error(`No CTM registered for chain ${firstChainId} on bridgehub ${bridgehubAddress}`);
  }
  return { governance, chainTypeManager };
}

async function main(): Promise<void> {
  const anvilManager = new AnvilManager();
  let cleanupUpgradeHarnessInputs: (() => void) | null = null;
  process.env.FOUNDRY_PROFILE = "anvil-interop";
  const keepChains = process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";

  // Env-preset mode: drive everything from `permanent-values/<preset>.toml`
  // (multi-CTM, ownable_proxies registry, governance_kind = puh, ...) instead
  // of the synthetic v30→v31 templating below. Set FORK_ENV_PRESET=stage (or
  // testnet/mainnet) to enable.
  const envPreset = process.env.FORK_ENV_PRESET?.trim();
  // L1-only smoke mode: skip L2 fork creation + L2 relay. Useful when L2
  // RPCs aren't available — exercises prepare + governance + per-chain L1
  // upgrade tx + stage3 only.
  const skipL2 = process.env.FORK_SKIP_L2 === "1";
  // Skip the per-chain upgrade phase entirely. Use when targeted chains are
  // not on the `old_protocol_version` the prepare-input expects (e.g. stage
  // chains lagging behind v29 — `upgradeCutDataBlock[chainVersion]` is empty
  // and `GetDiamondCutData.getDiamondCutData` reverts with `NoLogsFound`).
  // Lets us still reach + validate `ecosystem stage3` on the same fork.
  const skipChainUpgrades = process.env.FORK_SKIP_CHAIN_UPGRADES === "1";

  try {
    // ── Step 0: Load fork config ─────────────────────────────────
    console.log(`\n=== Step 0: Loading fork config (${elapsed()}) ===\n`);
    const cfg = loadForkConfig(path.join(anvilInteropDir, "config"));
    console.log(`  L1 fork URL:     ${cfg.l1ForkUrl}`);
    if (cfg.l1ForkBlock !== undefined) {
      console.log(`  L1 fork block:   ${cfg.l1ForkBlock}`);
    }
    console.log(`  Bridgehub:       ${cfg.bridgehubAddress}`);
    if (cfg.chainIdFilter.length > 0) {
      console.log(`  Chain ID filter: ${cfg.chainIdFilter.join(", ")}`);
    }

    // ── Step 1: Start forked L1 ──────────────────────────────────
    // Probe the upstream L1 RPC for its real chain ID and fork with it. Using
    // a synthetic 31337 makes NTV.originToken(baseTokenAssetId) revert during
    // per-chain v31 upgrades because the asset's stored originChainId equals
    // the upstream's real chain ID (e.g. Sepolia 11155111) and `originChainId !=
    // block.chainid` routes the lookup down the bridged-token branch. Matching
    // the real chain ID makes the production short-circuit fire correctly.
    console.log(`\n=== Step 1: Starting forked L1 anvil (${elapsed()}) ===\n`);
    const upstreamProvider = new ethers.providers.JsonRpcProvider(cfg.l1ForkUrl);
    const upstreamChainId = (await upstreamProvider.getNetwork()).chainId;
    runtimeConfig.l1ChainId = upstreamChainId;
    console.log(`  Upstream L1 chain ID: ${upstreamChainId}`);
    await anvilManager.startChain({
      chainId: upstreamChainId,
      port: allocatePort(0),
      role: "l1",
      forkUrl: cfg.l1ForkUrl,
      forkBlockNumber: cfg.l1ForkBlock,
    });
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) throw new Error("L1 chain failed to start");
    const l1Provider = new ethers.providers.JsonRpcProvider(l1Chain.rpcUrl);

    // ── Step 2: Discover chains from forked Bridgehub ────────────
    console.log(`\n=== Step 2: Discovering chains from Bridgehub (${elapsed()}) ===\n`);
    const chains = skipL2 ? await discoverForkChainsL1Only(l1Provider, cfg) : await discoverForkChains(l1Provider, cfg);
    for (const c of chains) {
      console.log(
        `  Chain ${c.chainId}: diamondProxy=${c.diamondProxy} admin=${c.chainAdmin}` +
          (c.l2RpcUrl ? ` l2Rpc=${c.l2RpcUrl}` : " l2Rpc=<skipped>")
      );
    }

    // ── Step 3: Start forked L2 anvils ───────────────────────────
    if (skipL2) {
      console.log("\n=== Step 3: Skipped (FORK_SKIP_L2=1, L1-only mode) ===\n");
    } else {
      console.log(`\n=== Step 3: Starting forked L2 anvils (${elapsed()}) ===\n`);
      for (let i = 0; i < chains.length; i++) {
        const c = chains[i];
        await anvilManager.startChain({
          chainId: c.chainId,
          port: allocatePort(1 + i),
          role: "directSettled",
          forkUrl: c.l2RpcUrl,
        });
      }
    }

    // ── Step 4: Resolve L1 addresses from forked state ───────────
    console.log(`\n=== Step 4: Resolving governance + CTM addresses (${elapsed()}) ===\n`);
    // In env-preset mode the bridgehub may have multiple CTMs (e.g. stage's
    // Era + Atlas), so we don't pin a single CTM here. Step 5 picks them up
    // from `permanent-values/<preset>.toml`'s [[ctm_contracts.ctms]] list, and
    // step 7 groups chains by their on-chain CTM.
    const governance: string = await new ethers.Contract(
      cfg.bridgehubAddress,
      getAbi("L1Bridgehub"),
      l1Provider
    ).owner();
    let chainTypeManager = "";
    if (!envPreset) {
      ({ chainTypeManager } = await resolveL1Addresses(l1Provider, cfg.bridgehubAddress, chains[0].chainId));
    }
    console.log(`  Governance: ${governance}`);
    if (chainTypeManager) console.log(`  CTM:        ${chainTypeManager}`);

    // ── Step 5: Run ecosystem upgrade forge scripts ──────────────
    console.log(`\n=== Step 5: Running v31 ecosystem upgrade prepare (${elapsed()}) ===\n`);
    const upgradeChainAddresses = chains.map((c) => ({ chainId: c.chainId, diamondProxy: c.diamondProxy }));

    let prepareDir: string;
    let upgradeHarnessInputsRef: ReturnType<typeof prepareUpgradeHarnessInputs> | null = null;
    let scenarioIsZKsyncOS = true;
    if (envPreset) {
      // Real env preset (stage / mainnet / testnet): drive prepare-all from
      // `permanent-values/<preset>.toml` directly. No template, no synthetic
      // upgrade-input — the canonical artifacts already live in the repo.
      const outBaseDir = path.join(anvilInteropDir, "outputs", `fork-upgrade-${envPreset}`);
      fs.rmSync(outBaseDir, { recursive: true, force: true });
      cleanupUpgradeHarnessInputs = () => fs.rmSync(outBaseDir, { recursive: true, force: true });
      const result = await runEcosystemUpgradeScriptsForEnv({
        envName: envPreset,
        rpcUrl: l1Chain.rpcUrl,
        bridgehubAddress: cfg.bridgehubAddress,
        outBaseDir,
        executeBundles: true,
      });
      prepareDir = result.prepareOutDir;
    } else {
      const scenario: V31UpgradeScenario = {
        label: "fork-v30-to-v31",
        stateVersion: "fork",
        permanentValuesTemplatePath:
          process.env.FORK_PERMANENT_VALUES_PATH ?? "upgrade-envs/permanent-values/local.toml",
        upgradeInputTemplatePath:
          process.env.FORK_UPGRADE_INPUT_PATH ?? "upgrade-envs/v0.30.0-zksync-os-blobs/localhost.toml",
        isZKsyncOS: true,
        targetRoles: ["directSettled"],
      };
      scenarioIsZKsyncOS = scenario.isZKsyncOS;
      const upgradeHarnessInputs = prepareUpgradeHarnessInputs(scenario, {
        l1Addresses: { bridgehub: cfg.bridgehubAddress, governance },
        ctmAddresses: { chainTypeManager },
        chainAddresses: upgradeChainAddresses,
      });
      upgradeHarnessInputsRef = upgradeHarnessInputs;
      cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;
      await runEcosystemUpgradeScripts({
        rpcUrl: l1Chain.rpcUrl,
        upgradeHarnessInputs,
        executeBundles: true,
      });
      prepareDir = path.join(upgradeHarnessInputs.protocolOpsOutDir, "prepare");
    }

    // ── Step 6: Execute governance stages 0/1/2 ──────────────────
    // Direct-impersonate path: `bridgehub.owner()` on stage / mainnet is a
    // ProtocolUpgradeHandler proxy (no `Ownable.owner()`), so `anvil
    // --auto-impersonate` lets us send the governance txs *as* the handler.
    // After folding gov-upgrade.toml into governance.toml (#0dd085d53), this
    // is one TOML, not two.
    console.log(`\n=== Step 6: Executing governance calls (${elapsed()}) ===\n`);
    const govTomlPath = path.join(prepareDir, "governance.toml");
    if (!fs.existsSync(govTomlPath)) {
      throw new Error(`No governance.toml emitted by upgrade-prepare-all at ${govTomlPath}`);
    }
    const calls = (readEcosystemOutput(govTomlPath).governance_calls ?? {}) as Record<string, string>;
    if (!calls.stage0_calls) {
      throw new Error(`governance.toml missing governance_calls section: ${govTomlPath}`);
    }
    await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(calls.stage0_calls), "Stage 0");

    // Stage 0 starts the GovernanceUpgradeTimer; stage 1's first call is
    // `checkDeadline()` which reverts unless `block.timestamp >= deadline`.
    // Fast-forward anvil time so stage 1 can proceed without waiting wall-clock.
    await advanceL1TimePastUpgradeDeadline(l1Provider);

    await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(calls.stage1_calls), "Stage 1");
    await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(calls.stage2_calls), "Stage 2");

    // NOTE: skip clearGenesisUpgradeTxHash / seedBatchCounters — real fork state
    // already has correct values for both.

    // ── Step 7: Per-chain ChainUpgrade_v31 (+ L2 relay if not skipL2) ──
    if (skipChainUpgrades) {
      console.log("\n=== Step 7: Skipped (FORK_SKIP_CHAIN_UPGRADES=1) ===\n");
    } else {
      console.log(`\n=== Step 7: Per-chain ChainUpgrade_v31 (${elapsed()}) ===\n`);
      const chainsOutDir = upgradeHarnessInputsRef
        ? path.join(upgradeHarnessInputsRef.protocolOpsOutDir, "chains")
        : path.join(anvilInteropDir, "outputs", `fork-upgrade-${envPreset!}`, "chains");
      if (envPreset) {
        // Multi-CTM-aware path. Groups chains by on-chain CTM and looks up the
        // SettlementLayerV31Upgrade addr per CTM from its prepare-output toml.
        await runChainUpgradesPerCtm({
          l1Provider,
          anvilManager,
          bridgehubAddr: cfg.bridgehubAddress,
          upgradeChainAddresses,
          protocolOpsOutDir: chainsOutDir,
          skipL2Relay: skipL2,
        });
      } else {
        const ctmTomlPath = path.join(
          l1ContractsDir,
          "script-out",
          `v31-upgrade-ctm-${chainTypeManager.toLowerCase()}.toml`
        );
        const ctmOutputToml = readEcosystemOutput(ctmTomlPath);
        const settlementLayerUpgradeAddr = readNestedString(
          ctmOutputToml,
          ["state_transition", "default_upgrade_addr"],
          "SettlementLayerV31Upgrade address"
        );
        await runChainUpgradesAndRelayL2({
          l1Provider,
          anvilManager,
          bridgehubAddr: cfg.bridgehubAddress,
          settlementLayerUpgradeAddr,
          ctmAddr: chainTypeManager,
          upgradeChainAddresses,
          isZKsyncOS: scenarioIsZKsyncOS,
          protocolOpsOutDir: chainsOutDir,
        });
      }
    }

    // ── Step 8: Stage 3 post-governance migration ────────────────
    console.log(`\n=== Step 8: Running stage3 (${elapsed()}) ===\n`);
    if (envPreset) {
      // Production stage3 entry point on the real upgrade contract — same
      // forge script protocol-ops `ecosystem stage3` invokes. The bridgehub
      // is passed as the lone positional arg.
      await runForgeScript({
        scriptPath: "deploy-scripts/upgrade/v31/CoreUpgrade_v31.s.sol:CoreUpgrade_v31",
        envVars: {},
        rpcUrl: l1Chain.rpcUrl,
        senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
        projectRoot: l1ContractsDir,
        sig: "stage3(address)",
        args: cfg.bridgehubAddress,
      });
    } else {
      await runForgeScript({
        scriptPath: "test/foundry/l1/integration/_EcosystemUpgradeV31ForTests.sol:CoreUpgradeV31ForTests",
        envVars: upgradeHarnessInputsRef!.envVars,
        rpcUrl: l1Chain.rpcUrl,
        senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
        projectRoot: l1ContractsDir,
        sig: "stage3()",
      });
    }

    // ── Step 9: Verify protocol version bump ─────────────────────
    if (skipL2) {
      console.log("\n=== Step 9: Skipped protocol-version verify (FORK_SKIP_L2=1, no L2 forks) ===\n");
    } else {
      console.log(`\n=== Step 9: Verifying protocol versions (${elapsed()}) ===\n`);
      await verifyProtocolVersions(l1Provider, upgradeChainAddresses);
    }

    console.log(`\n=== Fork-mode upgrade test completed successfully! (${elapsed()}) ===\n`);
  } finally {
    // Skip output cleanup so the protocol-ops bundles + ecosystem TOML stay on disk
    // for post-mortem inspection (e.g. when iterating on real-fork failures).
    const keepOutputs = process.env.FORK_KEEP_OUTPUTS === "1";
    if (cleanupUpgradeHarnessInputs && !keepOutputs) cleanupUpgradeHarnessInputs();
    if (!keepChains) {
      await anvilManager.stopAll();
    }
  }
}

main().catch((error) => {
  console.error("Fork-mode upgrade test failed:", error instanceof Error ? error.message : error);
  process.exit(1);
});

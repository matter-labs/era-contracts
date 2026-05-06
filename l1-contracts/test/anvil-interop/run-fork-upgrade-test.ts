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
  runEcosystemUpgradeScripts,
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
    const chains = await discoverForkChains(l1Provider, cfg);
    for (const c of chains) {
      console.log(`  Chain ${c.chainId}: diamondProxy=${c.diamondProxy} admin=${c.chainAdmin} l2Rpc=${c.l2RpcUrl}`);
    }

    // ── Step 3: Start forked L2 anvils ───────────────────────────
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

    // ── Step 4: Resolve L1 addresses from forked state ───────────
    console.log(`\n=== Step 4: Resolving governance + CTM addresses (${elapsed()}) ===\n`);
    const { governance, chainTypeManager } = await resolveL1Addresses(
      l1Provider,
      cfg.bridgehubAddress,
      chains[0].chainId
    );
    console.log(`  Governance: ${governance}`);
    console.log(`  CTM:        ${chainTypeManager}`);

    // ── Step 5: Run ecosystem upgrade forge scripts ──────────────
    console.log(`\n=== Step 5: Running v31 ecosystem upgrade prepare (${elapsed()}) ===\n`);
    const scenario: V31UpgradeScenario = {
      label: "fork-v30-to-v31",
      stateVersion: "fork", // unused in fork mode but required by the type
      permanentValuesTemplatePath: process.env.FORK_PERMANENT_VALUES_PATH ?? "upgrade-envs/permanent-values/local.toml",
      upgradeInputTemplatePath:
        process.env.FORK_UPGRADE_INPUT_PATH ?? "upgrade-envs/v0.30.0-zksync-os-blobs/localhost.toml",
      isZKsyncOS: true,
      targetRoles: ["directSettled"], // unused in fork mode but required by the type
    };
    const upgradeChainAddresses = chains.map((c) => ({ chainId: c.chainId, diamondProxy: c.diamondProxy }));

    const upgradeHarnessInputs = prepareUpgradeHarnessInputs(scenario, {
      l1Addresses: { bridgehub: cfg.bridgehubAddress, governance },
      ctmAddresses: { chainTypeManager },
      chainAddresses: upgradeChainAddresses,
    });
    cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;

    await runEcosystemUpgradeScripts({
      rpcUrl: l1Chain.rpcUrl,
      upgradeHarnessInputs,
      executeBundles: true,
    });

    // ── Step 6: Execute governance stages 0/1/2 ──────────────────
    // We intentionally bypass protocol-ops' `upgrade-governance` here. On decentralized-governance
    // stage/mainnet, `bridgehub.owner()` is a ProtocolUpgradeHandler proxy — not an Ownable2Step
    // `Governance.sol` — so protocol-ops' `resolve_governance_owner` (which does a two-level
    // `Ownable.owner()` hop) reverts. With `anvil --auto-impersonate` we can just send the
    // governance txs AS the handler address directly, which is what `executeGovernanceCalls` does.
    //
    // `upgrade-prepare-all` writes a single merged `governance.toml` directly
    // under `<out>/prepare/`. `gov upgrade-puh-guardians` (when run) emits a
    // sibling `gov-upgrade.toml`. We replay stages by re-emitting all stage-0
    // calls across both TOMLs, then all stage-1, then all stage-2 — matches
    // protocol-ops' `replay_governance_stages` ordering.
    console.log(`\n=== Step 6: Executing governance calls (${elapsed()}) ===\n`);
    const prepareDir = path.join(upgradeHarnessInputs.protocolOpsOutDir, "prepare");
    const govTomlPaths = ["governance.toml", "gov-upgrade.toml"]
      .map((name) => path.join(prepareDir, name))
      .filter((p) => fs.existsSync(p));
    if (govTomlPaths.length === 0) {
      throw new Error(`No governance TOMLs emitted by upgrade-prepare-all under ${prepareDir}`);
    }
    const stagesByToml = govTomlPaths.map((p) => {
      const calls = (readEcosystemOutput(p).governance_calls ?? {}) as Record<string, string>;
      if (!calls.stage0_calls) {
        throw new Error(`Governance TOML missing governance_calls section: ${p}`);
      }
      return calls;
    });
    for (const calls of stagesByToml) {
      await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(calls.stage0_calls), "Stage 0");
    }

    // Stage 0 starts the GovernanceUpgradeTimer; stage 1's first governance call
    // is `checkDeadline()` which reverts unless `block.timestamp >= deadline`.
    // On stage upgrades the configured `INITIAL_DELAY` is in the order of minutes
    // (e.g. 1200s on Sepolia), and the harness can't wait wall-clock — fast-forward
    // anvil time past the deadline so stage 1 can proceed.
    await advanceL1TimePastUpgradeDeadline(l1Provider);

    for (const calls of stagesByToml) {
      await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(calls.stage1_calls), "Stage 1");
    }
    for (const calls of stagesByToml) {
      await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(calls.stage2_calls), "Stage 2");
    }

    // NOTE: we intentionally skip clearGenesisUpgradeTxHash / seedBatchCounters that the
    // synthetic-state runner does — real forked chain state already has correct values for both.

    // ── Step 7: Per-chain ChainUpgrade_v31 + L2 relay ────────────
    console.log(`\n=== Step 7: Per-chain ChainUpgrade_v31 + L2 relay (${elapsed()}) ===\n`);
    // `default_upgrade_addr` lives in the per-CTM output TOML written by
    // `CTMUpgradeV31ForTests.saveOutput` directly to `<l1-contracts>/script-out/`
    // (forge writes it there; protocol-ops no longer copies it into `prepare/`).
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
      isZKsyncOS: scenario.isZKsyncOS,
      protocolOpsOutDir: path.join(upgradeHarnessInputs.protocolOpsOutDir, "chains"),
    });

    // ── Step 8: Stage 3 post-governance migration ────────────────
    console.log(`\n=== Step 8: Running stage3 (${elapsed()}) ===\n`);
    await runForgeScript({
      scriptPath: "test/foundry/l1/integration/_EcosystemUpgradeV31ForTests.sol:CoreUpgradeV31ForTests",
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "stage3()",
    });

    // ── Step 9: Verify protocol version bump ─────────────────────
    console.log(`\n=== Step 9: Verifying protocol versions (${elapsed()}) ===\n`);
    await verifyProtocolVersions(l1Provider, upgradeChainAddresses);

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

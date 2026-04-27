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
  type V31UpgradeScenario,
} from "./src/helpers/v31-upgrade-test-runner";

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
    // Chain ID forced to 31337 so that the `broadcast/ChainUpgrade_v31.s.sol/31337/` path
    // used by runChainUpgradesAndRelayL2 resolves correctly. This matches what the pre-generated
    // state harness does and what the upgrade scripts themselves expect in test mode.
    console.log(`\n=== Step 1: Starting forked L1 anvil (${elapsed()}) ===\n`);
    await anvilManager.startChain({
      chainId: 31337,
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
    console.log(`\n=== Step 6: Executing governance calls (${elapsed()}) ===\n`);
    const outputToml = readEcosystemOutput(upgradeHarnessInputs.ecosystemOutputPath);
    const govCalls = outputToml.governance_calls as Record<string, string> | undefined;
    if (!govCalls) {
      throw new Error("No governance_calls section in ecosystem output");
    }
    await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(govCalls.stage0_calls), "Stage 0");
    await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(govCalls.stage1_calls), "Stage 1");
    await executeGovernanceCalls(l1Provider, governance, decodeGovernanceCalls(govCalls.stage2_calls), "Stage 2");

    // NOTE: we intentionally skip clearGenesisUpgradeTxHash / seedBatchCounters that the
    // synthetic-state runner does — real forked chain state already has correct values for both.

    // ── Step 7: Per-chain ChainUpgrade_v31 + L2 relay ────────────
    console.log(`\n=== Step 7: Per-chain ChainUpgrade_v31 + L2 relay (${elapsed()}) ===\n`);
    const settlementLayerUpgradeAddr = readNestedString(
      outputToml,
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
      ecosystemYamlPath: upgradeHarnessInputs.ecosystemYamlPath,
      protocolOpsOutDir: path.join(upgradeHarnessInputs.protocolOpsOutDir, "chains"),
    });

    // ── Step 8: Stage 3 post-governance migration ────────────────
    console.log(`\n=== Step 8: Running stage3 (${elapsed()}) ===\n`);
    await runForgeScript({
      scriptPath: "test/foundry/l1/integration/_EcosystemUpgradeV31ForTests.sol:EcosystemUpgradeV31ForTests",
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

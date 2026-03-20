#!/usr/bin/env node

/**
 * V29 → V31 Upgrade Test
 *
 * Loads pre-generated v0.29.0 chain states, runs the v31 ecosystem upgrade
 * via the existing EcosystemUpgrade_v31 forge script, executes governance calls,
 * and verifies the upgrade succeeded.
 */

import * as fs from "fs";
import * as path from "path";
import { parse as parseToml } from "toml";
import { ethers } from "ethers";
import { AnvilManager } from "./src/daemons/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { runForgeScript } from "./src/core/forge";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_PRIVATE_KEY } from "./src/core/const";
import { L1_CHAIN_ID, L2_ASSET_TRACKER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR } from "./src/core/const";
import { getAbi, getCreationBytecode } from "./src/core/contracts";
import { transferOwnable2Step } from "./src/helpers/harness-shims";
import { impersonateAndRun } from "./src/core/utils";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");
const totalStart = Date.now();
const keepChains = process.env.ANVIL_INTEROP_KEEP_CHAINS === "1";

function elapsed(): string {
  return `${((Date.now() - totalStart) / 1000).toFixed(1)}s`;
}

function prepareUpgradeHarnessInputs(): {
  envVars: Record<string, string>;
  ecosystemOutputPath: string;
  cleanup: () => void;
} {
  const tempDir = path.join(anvilInteropDir, "outputs", "upgrade-harness-inputs");
  fs.mkdirSync(tempDir, { recursive: true });

  const permanentValuesPath = path.join(tempDir, "v29-permanent-values.toml");
  const upgradeInputPath = path.join(tempDir, "v29-to-v31-upgrade.toml");
  const ecosystemOutputPath = path.join(tempDir, "v31-upgrade-ecosystem.toml");

  fs.copyFileSync(path.join(anvilInteropDir, "config/v29-permanent-values.toml"), permanentValuesPath);
  fs.copyFileSync(path.join(anvilInteropDir, "config/v29-to-v31-upgrade.toml"), upgradeInputPath);

  console.log("  Prepared temporary upgrade harness inputs");

  return {
    envVars: {
      PERMANENT_VALUES_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, permanentValuesPath)}`,
      UPGRADE_INPUT_OVERRIDE: `/${path.relative(l1ContractsDir, upgradeInputPath)}`,
      UPGRADE_ECOSYSTEM_OUTPUT_OVERRIDE: `/${path.relative(l1ContractsDir, ecosystemOutputPath)}`,
    },
    ecosystemOutputPath,
    cleanup: () => {
      fs.rmSync(tempDir, { recursive: true, force: true });
      console.log("  Removed temporary upgrade harness inputs");
    },
  };
}

function readNestedString(
  value: Record<string, unknown>,
  pathSegments: string[],
  label: string
): string {
  let current: unknown = value;
  for (const segment of pathSegments) {
    if (!current || typeof current !== "object" || !(segment in current)) {
      throw new Error(`Missing ${label} at ${pathSegments.join(".")}`);
    }
    current = (current as Record<string, unknown>)[segment];
  }

  if (typeof current !== "string" || current.length === 0) {
    throw new Error(`Invalid ${label} at ${pathSegments.join(".")}`);
  }

  return current;
}

function decodeLatestL2UpgradeTxData(broadcastPath: string): string {
  const broadcast = JSON.parse(fs.readFileSync(broadcastPath, "utf8")) as {
    transactions?: Array<{ input?: string; transaction?: { input?: string } }>;
  };
  const transactions = broadcast.transactions || [];
  if (transactions.length === 0) {
    throw new Error(`No transactions found in broadcast file ${broadcastPath}`);
  }

  const chainAdminIface = new ethers.utils.Interface(getAbi("ChainAdminOwnable"));
  const adminIface = new ethers.utils.Interface(getAbi("AdminFacet"));
  const settlementLayerUpgradeIface = new ethers.utils.Interface(getAbi("SettlementLayerV31Upgrade"));
  for (const transaction of [...transactions].reverse()) {
    const input = transaction.transaction?.input ?? transaction.input;
    if (typeof input !== "string" || input.length <= 10) {
      continue;
    }

    try {
      const multicallDecoded = chainAdminIface.decodeFunctionData("multicall", input);
      const calls = multicallDecoded[0] as Array<{ target: string; value: ethers.BigNumber; data: string }>;
      if (calls.length !== 1) {
        continue;
      }

      const adminCall = adminIface.decodeFunctionData("upgradeChainFromVersion", calls[0].data);
      const diamondCutData = adminCall[1] as { initCalldata: string };
      const proposedUpgrade = settlementLayerUpgradeIface.decodeFunctionData("upgrade", diamondCutData.initCalldata)[0] as {
        l2ProtocolUpgradeTx: { from: ethers.BigNumber; to: ethers.BigNumber; value: ethers.BigNumber; data: string };
      };

      return proposedUpgrade.l2ProtocolUpgradeTx.data;
    } catch {
      continue;
    }
  }

  throw new Error(`Missing upgradeChainFromVersion multicall input in ${broadcastPath}`);
}

async function executeL2UpgradeTxs(
  l1Provider: ethers.providers.JsonRpcProvider,
  anvilManager: AnvilManager,
  bridgehubAddr: string,
  settlementLayerUpgradeAddr: string,
  chainAddresses: Array<{ chainId: number; diamondProxy: string }>,
  upgradeTxDataByChainId: Map<number, string>
): Promise<void> {
  const settlementLayerUpgrade = new ethers.Contract(
    settlementLayerUpgradeAddr,
    getAbi("SettlementLayerV31Upgrade"),
    l1Provider
  );
  const complexUpgraderIface = new ethers.utils.Interface(getAbi("L2ComplexUpgrader"));

  for (const chain of chainAddresses) {
    const l2Chain = anvilManager.getL2Chains().find((candidate) => candidate.chainId === chain.chainId);
    if (!l2Chain) {
      throw new Error(`Missing running L2 chain ${chain.chainId}`);
    }

    const l2Provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);
    const originalUpgradeTxData = upgradeTxDataByChainId.get(chain.chainId);
    if (!originalUpgradeTxData) {
      throw new Error(`Missing decoded L2 upgrade tx data for chain ${chain.chainId}`);
    }
    const l2V31UpgradeCalldata: string = await settlementLayerUpgrade.getL2V31UpgradeCalldata(
      bridgehubAddr,
      chain.chainId
    );

    const selector = originalUpgradeTxData.slice(0, 10);
    let outerCalldata: string;
    if (selector === complexUpgraderIface.getSighash("forceDeployAndUpgrade")) {
      const decodedOuter = complexUpgraderIface.decodeFunctionData("forceDeployAndUpgrade", originalUpgradeTxData);
      outerCalldata = complexUpgraderIface.encodeFunctionData("forceDeployAndUpgrade", [
        decodedOuter[0],
        decodedOuter[1],
        l2V31UpgradeCalldata,
      ]);
    } else if (selector === complexUpgraderIface.getSighash("forceDeployAndUpgradeUniversal")) {
      const decodedOuter = complexUpgraderIface.decodeFunctionData(
        "forceDeployAndUpgradeUniversal",
        originalUpgradeTxData
      );
      outerCalldata = complexUpgraderIface.encodeFunctionData("forceDeployAndUpgradeUniversal", [
        decodedOuter[0],
        decodedOuter[1],
        l2V31UpgradeCalldata,
      ]);
    } else {
      throw new Error(`Unexpected L2 upgrade selector for chain ${chain.chainId}: ${selector}`);
    }

    console.log(`  Chain ${chain.chainId}: executing relayed L2 upgrade tx`);
    const relayReceipt = await impersonateAndRun(l2Provider, L2_FORCE_DEPLOYER_ADDR, async (signer) => {
      const tx = await signer.sendTransaction({
        to: L2_COMPLEX_UPGRADER_ADDR,
        data: outerCalldata,
        gasLimit: 100_000_000,
      });
      return tx.wait();
    });
    if (relayReceipt.status !== 1) {
      throw new Error(`L2 upgrade relay failed for chain ${chain.chainId}: ${relayReceipt.transactionHash}`);
    }

    const assetTracker = new ethers.Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), l2Provider);
    const assetTrackerL1ChainId = await assetTracker.L1_CHAIN_ID();
    if (!assetTrackerL1ChainId.eq(L1_CHAIN_ID)) {
      throw new Error(
        `Chain ${chain.chainId} L2AssetTracker.L1_CHAIN_ID mismatch: expected ${L1_CHAIN_ID}, got ${assetTrackerL1ChainId.toString()}`
      );
    }

    const baseTokenAssetId = await assetTracker.BASE_TOKEN_ASSET_ID();
    const isBaseTokenRegistered = await assetTracker.isAssetRegistered(baseTokenAssetId);
    if (!isBaseTokenRegistered) {
      throw new Error(`Chain ${chain.chainId} base token was not registered by the relayed L2 upgrade`);
    }

    console.log(`  Chain ${chain.chainId}: relayed L2 upgrade executed successfully (${relayReceipt.transactionHash})`);
  }
}

/**
 * Decode ABI-encoded Call[] from hex bytes.
 * Call = tuple(address target, uint256 value, bytes data)
 */
function decodeGovernanceCalls(hexBytes: string): Array<{ target: string; value: ethers.BigNumber; data: string }> {
  const abiCoder = ethers.utils.defaultAbiCoder;
  const [calls] = abiCoder.decode(["tuple(address,uint256,bytes)[]"], hexBytes);
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return calls.map((c: any) => ({
    target: c[0],
    value: c[1],
    data: c[2],
  }));
}

/**
 * Execute governance calls by impersonating the governance address on Anvil.
 */
async function executeGovernanceCalls(
  provider: ethers.providers.JsonRpcProvider,
  governanceAddr: string,
  calls: Array<{ target: string; value: ethers.BigNumber; data: string }>,
  stageName: string
): Promise<void> {
  if (calls.length === 0) {
    console.log(`  ${stageName}: no calls to execute`);
    return;
  }

  // Impersonate the governance contract
  await provider.send("anvil_impersonateAccount", [governanceAddr]);
  // Fund it for gas
  await provider.send("anvil_setBalance", [governanceAddr, "0x56BC75E2D63100000"]);

  const signer = provider.getSigner(governanceAddr);

  for (let i = 0; i < calls.length; i++) {
    const call = calls[i];
    console.log(`  ${stageName} call ${i + 1}/${calls.length}: ${call.target}`);
    const tx = await signer.sendTransaction({
      to: call.target,
      value: call.value,
      data: call.data,
      gasLimit: 30_000_000,
    });
    const receipt = await tx.wait();
    if (receipt.status !== 1) {
      throw new Error(`${stageName} call ${i + 1} reverted (tx: ${receipt.transactionHash})`);
    }
  }

  await provider.send("anvil_stopImpersonatingAccount", [governanceAddr]);
  console.log(`  ${stageName}: ${calls.length} calls executed successfully`);
}

/**
 * Transfer ownership of an Ownable2StepUpgradeable contract to the governance address.
 * Two-step: transferOwnership (from current owner) + acceptOwnership (from new owner).
 */
async function transferOwnership2Step(
  provider: ethers.providers.JsonRpcProvider,
  defaultSigner: ethers.Wallet,
  governanceAddr: string,
  contractAddr: string,
  label: string
): Promise<void> {
  const ownableContract = new ethers.Contract(contractAddr, getAbi("Ownable2Step"), provider);

  const currentOwner = await ownableContract.owner();
  if (currentOwner.toLowerCase() === governanceAddr.toLowerCase()) {
    console.log(`  ${label}: already owned by governance`);
    return;
  }

  console.log(`  ${label}: transferring ownership from ${currentOwner} to ${governanceAddr}`);

  if (currentOwner.toLowerCase() !== defaultSigner.address.toLowerCase()) {
    throw new Error(`${label}: expected deployer to remain owner, found ${currentOwner}`);
  }

  await transferOwnable2Step(provider, contractAddr, getAbi("Ownable2Step"), currentOwner, governanceAddr);

  console.log(`  ${label}: ownership transferred`);
}

async function applyV29UpgradeHarnessPatches(
  provider: ethers.providers.JsonRpcProvider,
  chainAddresses: Array<{ chainId: number; diamondProxy: string }>
): Promise<void> {
  const TOTAL_BATCHES_EXECUTED_SLOT = "0x0b";
  const TOTAL_BATCHES_VERIFIED_SLOT = "0x0c";
  const TOTAL_BATCHES_COMMITTED_SLOT = "0x0d";
  const L2_SYSTEM_CONTRACTS_UPGRADE_TX_HASH_SLOT = "0x22";
  const ZKSYNC_OS_SLOT = "0x3c";
  const ONE = ethers.utils.hexZeroPad("0x01", 32);

  for (const chain of chainAddresses) {
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, TOTAL_BATCHES_EXECUTED_SLOT, ONE]);
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, TOTAL_BATCHES_VERIFIED_SLOT, ONE]);
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, TOTAL_BATCHES_COMMITTED_SLOT, ONE]);
    await provider.send("anvil_setStorageAt", [
      chain.diamondProxy,
      L2_SYSTEM_CONTRACTS_UPGRADE_TX_HASH_SLOT,
      ethers.constants.HashZero,
    ]);
    await provider.send("anvil_setStorageAt", [chain.diamondProxy, ZKSYNC_OS_SLOT, ONE]);
    console.log(`  Chain ${chain.chainId}: patched batch counts, cleared upgradeTxHash, set zksyncOS=true`);
  }
}

async function main(): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  let cleanupUpgradeHarnessInputs: (() => void) | null = null;
  let upgradeHarnessInputs: {
    envVars: Record<string, string>;
    ecosystemOutputPath: string;
    cleanup: () => void;
  } | null = null;

  try {
    // ── Step 1: Load v29 chain states ───────────────────────────────
    console.log(`\n=== Step 1: Loading v0.29.0 chain states (${elapsed()}) ===\n`);

    const v29StateDir = path.join(anvilInteropDir, "chain-states/v0.29.0");
    if (!fs.existsSync(path.join(v29StateDir, "addresses.json"))) {
      throw new Error("v0.29.0 chain states not found. Generate them first.");
    }

    const { l1Addresses, ctmAddresses, chainAddresses } = await runner.loadChainStates(anvilManager, v29StateDir);
    const l1Chain = anvilManager.getL1Chain();
    if (!l1Chain) throw new Error("L1 chain not started");

    const provider = new ethers.providers.JsonRpcProvider(l1Chain.rpcUrl);
    const defaultSigner = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, provider);
    const governanceAddr = l1Addresses.governance;
    const ctmAddress = ctmAddresses.chainTypeManager;

    console.log(`  L1 RPC: ${l1Chain.rpcUrl}`);
    console.log(`  Bridgehub: ${l1Addresses.bridgehub}`);
    console.log(`  Governance: ${governanceAddr}`);
    console.log(`  CTM: ${ctmAddress}`);

    // Ensure script-out directory exists
    // ── Step 1.5: Transfer ownership to Governance ──────────────────
    console.log(`\n=== Step 1.5: Transferring contract ownership to Governance (${elapsed()}) ===\n`);

    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.bridgehub, "Bridgehub");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.l1SharedBridge, "L1AssetRouter");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, ctmAddress, "CTM");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.l1AssetTracker, "L1AssetTracker");

    // ── Step 1.6: Deploy ChainAdminOwnable for each chain ───────────
    console.log(`\n=== Step 1.6: Deploying ChainAdminOwnable per chain (${elapsed()}) ===\n`);

    const chainAdminFactory = new ethers.ContractFactory(
      getAbi("ChainAdminOwnable"),
      getCreationBytecode("ChainAdminOwnable"),
      defaultSigner
    );

    for (const chain of chainAddresses) {
      const diamondProxy = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
      const currentAdmin = await diamondProxy.getAdmin();
      console.log(`  Chain ${chain.chainId}: current admin = ${currentAdmin}`);

      // Deploy a new ChainAdminOwnable owned by the deployer
      const chainAdmin = await chainAdminFactory.deploy(ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_ACCOUNT_ADDR);
      await chainAdmin.deployed();
      console.log(`  Chain ${chain.chainId}: deployed ChainAdminOwnable at ${chainAdmin.address}`);

      // Set the new admin on the diamond proxy (must be called by current admin)
      await provider.send("anvil_impersonateAccount", [currentAdmin]);
      await provider.send("anvil_setBalance", [currentAdmin, "0x56BC75E2D63100000"]);
      const adminSigner = provider.getSigner(currentAdmin);
      const setPendingAdminData = new ethers.utils.Interface(getAbi("AdminFacet")).encodeFunctionData(
        "setPendingAdmin",
        [chainAdmin.address]
      );
      const tx = await adminSigner.sendTransaction({
        to: chain.diamondProxy,
        data: setPendingAdminData,
        gasLimit: 1_000_000,
      });
      await tx.wait();
      await provider.send("anvil_stopImpersonatingAccount", [currentAdmin]);

      // Accept admin via ChainAdminOwnable.multicall → diamondProxy.acceptAdmin()
      const acceptAdminData = new ethers.utils.Interface(getAbi("AdminFacet")).encodeFunctionData("acceptAdmin", []);
      const chainAdminContract = new ethers.Contract(chainAdmin.address, getAbi("ChainAdminOwnable"), defaultSigner);
      const multicallTx = await chainAdminContract.multicall(
        [{ target: chain.diamondProxy, value: 0, data: acceptAdminData }],
        true
      );
      await multicallTx.wait();

      // Verify new admin
      const newAdmin = await diamondProxy.getAdmin();
      console.log(`  Chain ${chain.chainId}: new admin = ${newAdmin}`);
    }

    // ── Step 2: Swap configs and run EcosystemUpgrade_v31 ─────────
    console.log(`\n=== Step 2: Running v31 ecosystem upgrade (${elapsed()}) ===\n`);

    upgradeHarnessInputs = prepareUpgradeHarnessInputs();
    cleanupUpgradeHarnessInputs = upgradeHarnessInputs.cleanup;

    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol:EcosystemUpgrade_v31",
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "run()",
    });

    // ── Step 3: Execute governance calls ──────────────────────────
    console.log(`\n=== Step 3: Executing governance calls (${elapsed()}) ===\n`);

    const ecosystemOutputPath = upgradeHarnessInputs.ecosystemOutputPath;
    if (!fs.existsSync(ecosystemOutputPath)) {
      throw new Error(`Ecosystem output not found at ${ecosystemOutputPath}`);
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const outputToml = parseToml(fs.readFileSync(ecosystemOutputPath, "utf-8")) as Record<string, unknown>;
    const govCalls = outputToml.governance_calls as Record<string, string> | undefined;
    if (!govCalls) {
      throw new Error("No governance_calls section in ecosystem output");
    }

    const stage0Calls = decodeGovernanceCalls(govCalls.stage0_calls);
    const stage1Calls = decodeGovernanceCalls(govCalls.stage1_calls);
    const stage2Calls = decodeGovernanceCalls(govCalls.stage2_calls);

    console.log(`  Stage 0: ${stage0Calls.length} calls`);
    console.log(`  Stage 1: ${stage1Calls.length} calls`);
    console.log(`  Stage 2: ${stage2Calls.length} calls`);

    await executeGovernanceCalls(provider, governanceAddr, stage0Calls, "Stage 0");
    await executeGovernanceCalls(provider, governanceAddr, stage1Calls, "Stage 1");
    await executeGovernanceCalls(provider, governanceAddr, stage2Calls, "Stage 2");

    // ── Step 3.5: Patch v29 chain storage for v31 upgrade compatibility ─
    // The v29 chains were created on Anvil with state dumps (no real L2 execution),
    // so several storage slots need patching for the v31 upgrade to succeed:
    // 1. Clear l2SystemContractsUpgradeTxHash (slot 34/0x22): set from genesis but
    //    never finalized (no batches executed). Without clearing, ChainUpgrade_v31
    //    reverts with PreviousUpgradeNotFinalized.
    // 2. Set zksyncOS = true (slot 60/0x3c): v29 chains predate the zksyncOS flag
    //    (defaults to false), but the v31 upgrade generates tx type 126 (zksyncOS).
    //    Without this, the chain rejects the upgrade tx with InvalidTxType(126).
    // 3. Set totalBatchesExecuted/Verified/Committed (slots 11-13) to 1: v29 chains
    //    have zero batches. SettlementLayerV31Upgrade requires totalBatchesExecuted > 0
    //    (TotalBatchesExecutedZero) and totalBatchesCommitted == totalBatchesExecuted
    //    (NotAllBatchesExecuted).
    //
    // NOTE: Eventually the v29 state generation branch should be rebased on
    // zksync-os-stable, which would eliminate most of these patches.
    console.log(`\n=== Step 3.5: Patching v29 chain storage (${elapsed()}) ===\n`);
    await applyV29UpgradeHarnessPatches(provider, chainAddresses);

    // ── Step 4: Upgrade each chain individually ─────────────────
    console.log(`\n=== Step 4: Upgrading individual chains (${elapsed()}) ===\n`);

    const chainUpgradeBroadcastPath = path.join(
      l1ContractsDir,
      "broadcast/ChainUpgrade_v31.s.sol/31337/run-latest.json"
    );
    const upgradeTxDataByChainId = new Map<number, string>();

    for (const chain of chainAddresses) {
      console.log(`  Upgrading chain ${chain.chainId}...`);
      await runForgeScript({
        scriptPath: "deploy-scripts/upgrade/v31/ChainUpgrade_v31.s.sol:ChainUpgrade_v31",
        envVars: {},
        rpcUrl: l1Chain.rpcUrl,
        senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
        projectRoot: l1ContractsDir,
        sig: "run(address,uint256)",
        args: `${ctmAddress} ${chain.chainId}`,
      });
      upgradeTxDataByChainId.set(chain.chainId, decodeLatestL2UpgradeTxData(chainUpgradeBroadcastPath));
    }

    // ── Step 4.5: Execute relayed L2 upgrade txs ─────────────────
    console.log(`\n=== Step 4.5: Executing relayed L2 upgrade txs (${elapsed()}) ===\n`);

    const settlementLayerUpgradeAddr = readNestedString(
      outputToml,
      ["state_transition", "default_upgrade_addr"],
      "SettlementLayerV31Upgrade address"
    );
    await executeL2UpgradeTxs(
      provider,
      anvilManager,
      l1Addresses.bridgehub,
      settlementLayerUpgradeAddr,
      chainAddresses,
      upgradeTxDataByChainId
    );

    // ── Step 5: Run stage3 post-governance migration ─────────────
    console.log(`\n=== Step 5: Running stage3 migration (${elapsed()}) ===\n`);

    // Swap configs again for stage3 (it reads permanent values)
    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol:EcosystemUpgrade_v31",
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "stage3()",
    });

    // ── Step 6: Verify upgrade ───────────────────────────────────
    console.log(`\n=== Step 6: Verifying upgrade (${elapsed()}) ===\n`);

    const expectedVersion = ethers.BigNumber.from("0x1f00000000"); // v31

    for (const chain of chainAddresses) {
      const diamondProxy = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
      const protocolVersion = await diamondProxy.getProtocolVersion();
      const versionHex = "0x" + protocolVersion.toHexString().replace("0x", "").padStart(10, "0");
      console.log(`  Chain ${chain.chainId} (${chain.diamondProxy}): protocol version ${versionHex}`);

      if (!protocolVersion.eq(expectedVersion)) {
        throw new Error(
          `Chain ${chain.chainId} protocol version mismatch: expected ${expectedVersion.toHexString()}, got ${protocolVersion.toHexString()}`
        );
      }
    }
    console.log("  All chains upgraded to v31");

    console.log(`\n=== V29 -> V31 upgrade test completed successfully! (${elapsed()}) ===\n`);
  } finally {
    if (cleanupUpgradeHarnessInputs) cleanupUpgradeHarnessInputs();
    await anvilManager.stopAll();
  }
}

main().catch((error) => {
  console.error("V29->V31 upgrade test failed:", error.message || error);
  process.exit(1);
});

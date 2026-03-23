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
import { getAbi, getCreationBytecode } from "./src/core/contracts";
import type { ChainAddresses } from "./src/core/types";
import { transferOwnable2Step } from "./src/helpers/harness-shims";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");
const totalStart = Date.now();

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

/**
 * Decode ABI-encoded Call[] from hex bytes.
 * Call = tuple(address target, uint256 value, bytes data)
 */
interface GovernanceCall {
  target: string;
  value: ethers.BigNumber;
  data: string;
}

function decodeGovernanceCalls(hexBytes: string): GovernanceCall[] {
  const abiCoder = ethers.utils.defaultAbiCoder;
  const [calls] = abiCoder.decode(["tuple(address,uint256,bytes)[]"], hexBytes);
  return (calls as Array<[string, ethers.BigNumber, string]>).map((c) => ({
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
  calls: GovernanceCall[],
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
  chainAddresses: ChainAddresses[]
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

    // ── Step 2: Transfer ownership to Governance ──────────────────
    // The v29 state was generated by the deploy script which uses a deployer EOA as owner.
    // The v31 upgrade scripts expect Governance to own all core contracts, so we must
    // transfer ownership before running the upgrade.
    console.log(`\n=== Step 2: Transferring contract ownership to Governance (${elapsed()}) ===\n`);

    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.bridgehub, "Bridgehub");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.l1SharedBridge, "L1AssetRouter");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, ctmAddress, "CTM");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.l1AssetTracker, "L1AssetTracker");

    // ── Step 3: Deploy ChainAdminOwnable for each chain ───────────
    console.log(`\n=== Step 3: Deploying ChainAdminOwnable per chain (${elapsed()}) ===\n`);

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

    // ── Step 4: Swap configs and run EcosystemUpgrade_v31 ─────────
    console.log(`\n=== Step 4: Running v31 ecosystem upgrade (${elapsed()}) ===\n`);

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

    // ── Step 5: Execute governance calls ──────────────────────────
    console.log(`\n=== Step 5: Executing governance calls (${elapsed()}) ===\n`);

    const ecosystemOutputPath = upgradeHarnessInputs.ecosystemOutputPath;
    if (!fs.existsSync(ecosystemOutputPath)) {
      throw new Error(`Ecosystem output not found at ${ecosystemOutputPath}`);
    }

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

    // ── Step 6: Patch v29 chain storage for v31 upgrade compatibility ─
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
    console.log(`\n=== Step 6: Patching v29 chain storage (${elapsed()}) ===\n`);
    await applyV29UpgradeHarnessPatches(provider, chainAddresses);

    // ── Step 7: Upgrade each chain individually ─────────────────
    console.log(`\n=== Step 7: Upgrading individual chains (${elapsed()}) ===\n`);

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
    }

    // ── Step 8: Run stage3 post-governance migration ─────────────
    console.log(`\n=== Step 8: Running stage3 migration (${elapsed()}) ===\n`);

    // Swap configs again for stage3 (it reads permanent values)
    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol:EcosystemUpgrade_v31",
      envVars: upgradeHarnessInputs.envVars,
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "stage3()",
    });

    // ── Step 9: Verify upgrade ───────────────────────────────────
    console.log(`\n=== Step 9: Verifying upgrade (${elapsed()}) ===\n`);

    for (const chain of chainAddresses) {
      const diamondProxy = new ethers.Contract(chain.diamondProxy, getAbi("GettersFacet"), provider);
      const semver = await diamondProxy.getSemverProtocolVersion();
      const [major, minor, patch] = [semver[0].toNumber(), semver[1].toNumber(), semver[2].toNumber()];
      console.log(`  Chain ${chain.chainId} (${chain.diamondProxy}): protocol version ${major}.${minor}.${patch}`);

      if (major !== 0 || minor !== 31) {
        throw new Error(
          `Chain ${chain.chainId} protocol version mismatch: expected 0.31.x, got ${major}.${minor}.${patch}`
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

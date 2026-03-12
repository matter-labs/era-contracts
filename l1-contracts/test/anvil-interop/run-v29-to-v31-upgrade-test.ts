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
import { AnvilManager } from "./src/anvil-manager";
import { DeploymentRunner } from "./src/deployment-runner";
import { runForgeScript } from "./src/forge";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_DEFAULT_PRIVATE_KEY } from "./src/const";
import {
  adminFacetAbi,
  chainAdminOwnableAbi,
  chainAdminOwnableBytecode,
  ownable2StepAbi,
  gettersFacetAbi,
} from "./src/contracts";

const anvilInteropDir = __dirname;
const l1ContractsDir = path.resolve(__dirname, "../..");
const totalStart = Date.now();

function elapsed(): string {
  return `${((Date.now() - totalStart) / 1000).toFixed(1)}s`;
}

/**
 * Swap v29 config files into the paths that EcosystemUpgrade_v31.run() expects.
 * Returns a restore function that puts back the originals.
 */
function swapConfigFiles(): () => void {
  const permanentValuesPath = path.join(l1ContractsDir, "upgrade-envs/permanent-values/local.toml");
  const upgradeInputPath = path.join(l1ContractsDir, "upgrade-envs/v0.31.0-interopB/local.toml");

  const v29PermanentValues = path.join(anvilInteropDir, "config/v29-permanent-values.toml");
  const v29UpgradeInput = path.join(anvilInteropDir, "config/v29-to-v31-upgrade.toml");

  // Back up originals
  const permanentValuesBackup = permanentValuesPath + ".bak";
  const upgradeInputBackup = upgradeInputPath + ".bak";

  fs.copyFileSync(permanentValuesPath, permanentValuesBackup);
  fs.copyFileSync(upgradeInputPath, upgradeInputBackup);

  // Copy v29 configs to expected paths
  fs.copyFileSync(v29PermanentValues, permanentValuesPath);
  fs.copyFileSync(v29UpgradeInput, upgradeInputPath);

  console.log("  Swapped config files to v29 values");

  return () => {
    fs.copyFileSync(permanentValuesBackup, permanentValuesPath);
    fs.copyFileSync(upgradeInputBackup, upgradeInputPath);
    fs.unlinkSync(permanentValuesBackup);
    fs.unlinkSync(upgradeInputBackup);
    console.log("  Restored original config files");
  };
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
  const ownableContract = new ethers.Contract(contractAddr, ownable2StepAbi(), provider);

  const currentOwner = await ownableContract.owner();
  if (currentOwner.toLowerCase() === governanceAddr.toLowerCase()) {
    console.log(`  ${label}: already owned by governance`);
    return;
  }

  console.log(`  ${label}: transferring ownership from ${currentOwner} to ${governanceAddr}`);

  // Step 1: transferOwnership (from current owner, which is the deployer EOA)
  const tx1 = await ownableContract.connect(defaultSigner).transferOwnership(governanceAddr);
  await tx1.wait();

  // Step 2: acceptOwnership (from governance, impersonated)
  await provider.send("anvil_impersonateAccount", [governanceAddr]);
  await provider.send("anvil_setBalance", [governanceAddr, "0x56BC75E2D63100000"]);
  const govSigner = provider.getSigner(governanceAddr);
  const tx2 = await ownableContract.connect(govSigner).acceptOwnership();
  await tx2.wait();
  await provider.send("anvil_stopImpersonatingAccount", [governanceAddr]);

  console.log(`  ${label}: ownership transferred`);
}

async function main(): Promise<void> {
  const anvilManager = new AnvilManager();
  const runner = new DeploymentRunner();
  let restoreConfigs: (() => void) | null = null;

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
    const scriptOutDir = path.join(l1ContractsDir, "script-out");
    fs.mkdirSync(scriptOutDir, { recursive: true });

    // ── Step 1.5: Transfer ownership to Governance ──────────────────
    console.log(`\n=== Step 1.5: Transferring contract ownership to Governance (${elapsed()}) ===\n`);

    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.bridgehub, "Bridgehub");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.l1SharedBridge, "L1AssetRouter");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, ctmAddress, "CTM");
    await transferOwnership2Step(provider, defaultSigner, governanceAddr, l1Addresses.l1AssetTracker, "L1AssetTracker");

    // ── Step 1.6: Deploy ChainAdminOwnable for each chain ───────────
    console.log(`\n=== Step 1.6: Deploying ChainAdminOwnable per chain (${elapsed()}) ===\n`);

    const chainAdminFactory = new ethers.ContractFactory(
      chainAdminOwnableAbi(),
      chainAdminOwnableBytecode(),
      defaultSigner
    );

    for (const chain of chainAddresses) {
      const diamondProxy = new ethers.Contract(chain.diamondProxy, gettersFacetAbi(), provider);
      const currentAdmin = await diamondProxy.getAdmin();
      console.log(`  Chain ${chain.chainId}: current admin = ${currentAdmin}`);

      // Deploy a new ChainAdminOwnable owned by the deployer
      const chainAdmin = await chainAdminFactory.deploy(
        ANVIL_DEFAULT_ACCOUNT_ADDR,
        ANVIL_DEFAULT_ACCOUNT_ADDR
      );
      await chainAdmin.deployed();
      console.log(`  Chain ${chain.chainId}: deployed ChainAdminOwnable at ${chainAdmin.address}`);

      // Set the new admin on the diamond proxy (must be called by current admin)
      await provider.send("anvil_impersonateAccount", [currentAdmin]);
      await provider.send("anvil_setBalance", [currentAdmin, "0x56BC75E2D63100000"]);
      const adminSigner = provider.getSigner(currentAdmin);
      const setPendingAdminData = new ethers.utils.Interface(adminFacetAbi())
        .encodeFunctionData("setPendingAdmin", [chainAdmin.address]);
      const tx = await adminSigner.sendTransaction({
        to: chain.diamondProxy,
        data: setPendingAdminData,
        gasLimit: 1_000_000,
      });
      await tx.wait();
      await provider.send("anvil_stopImpersonatingAccount", [currentAdmin]);

      // Accept admin via ChainAdminOwnable.multicall → diamondProxy.acceptAdmin()
      const acceptAdminData = new ethers.utils.Interface(adminFacetAbi())
        .encodeFunctionData("acceptAdmin", []);
      const chainAdminContract = new ethers.Contract(chainAdmin.address, chainAdminOwnableAbi(), defaultSigner);
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

    restoreConfigs = swapConfigFiles();

    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol:EcosystemUpgrade_v31",
      envVars: {},
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "run()",
    });

    // Restore configs immediately after forge script completes
    restoreConfigs();
    restoreConfigs = null;

    // ── Step 3: Execute governance calls ──────────────────────────
    console.log(`\n=== Step 3: Executing governance calls (${elapsed()}) ===\n`);

    const ecosystemOutputPath = path.join(scriptOutDir, "v31-upgrade-ecosystem.toml");
    if (!fs.existsSync(ecosystemOutputPath)) {
      throw new Error(`Ecosystem output not found at ${ecosystemOutputPath}`);
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const outputToml = parseToml(fs.readFileSync(ecosystemOutputPath, "utf-8")) as any;
    const govCalls = outputToml.governance_calls;
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

    // ── Step 3.5: Clear pending genesis upgrade tx hash ────────────
    // The v29 state has l2SystemContractsUpgradeTxHash set from genesis, but no
    // batches were ever executed to finalize it. Clear it so ChainUpgrade_v31
    // doesn't revert with PreviousUpgradeNotFinalized.
    console.log(`\n=== Step 3.5: Clearing pending upgrade tx hashes (${elapsed()}) ===\n`);
    const L2_SYSTEM_CONTRACTS_UPGRADE_TX_HASH_SLOT = "0x22"; // storage slot 34
    for (const chain of chainAddresses) {
      await provider.send("anvil_setStorageAt", [
        chain.diamondProxy,
        L2_SYSTEM_CONTRACTS_UPGRADE_TX_HASH_SLOT,
        ethers.constants.HashZero,
      ]);
      console.log(`  Chain ${chain.chainId}: cleared l2SystemContractsUpgradeTxHash`);
    }

    // ── Step 4: Upgrade each chain individually ─────────────────
    console.log(`\n=== Step 4: Upgrading individual chains (${elapsed()}) ===\n`);

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

    // ── Step 5: Run stage3 post-governance migration ─────────────
    console.log(`\n=== Step 5: Running stage3 migration (${elapsed()}) ===\n`);

    // Swap configs again for stage3 (it reads permanent values)
    restoreConfigs = swapConfigFiles();

    await runForgeScript({
      scriptPath: "deploy-scripts/upgrade/v31/EcosystemUpgrade_v31.s.sol:EcosystemUpgrade_v31",
      envVars: {},
      rpcUrl: l1Chain.rpcUrl,
      senderAddress: ANVIL_DEFAULT_ACCOUNT_ADDR,
      projectRoot: l1ContractsDir,
      sig: "stage3()",
    });

    restoreConfigs();
    restoreConfigs = null;

    // ── Step 6: Verify upgrade ───────────────────────────────────
    console.log(`\n=== Step 6: Verifying upgrade (${elapsed()}) ===\n`);

    const expectedVersion = ethers.BigNumber.from("0x1f00000000"); // v31

    for (const chain of chainAddresses) {
      const diamondProxy = new ethers.Contract(chain.diamondProxy, gettersFacetAbi(), provider);
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
    if (restoreConfigs) restoreConfigs();
    await anvilManager.stopAll();
  }
}

main().catch((error) => {
  console.error("V29->V31 upgrade test failed:", error.message || error);
  process.exit(1);
});

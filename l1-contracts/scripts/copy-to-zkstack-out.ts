import { promises as fs } from "fs";
import * as path from "path";

/**
 * This script copies required contract JSON files from out/ to zkstack-out/
 * for use by zkstack_cli during build
 *
 * It extracts only the ABI from each JSON file to keep the output minimal
 */

const REQUIRED_CONTRACTS = [
  "L1Bridgehub.sol",
  "MessageRootBase.sol",
  "IZKChain.sol",
  "IValidatorTimelock.sol",
  "IChainAssetHandler.sol",
  "IChainTypeManager.sol",
  "IAdmin.sol",
  "IDiamondCut.sol",
  "IChainAdminOwnable.sol",
  "IRegisterZKChain.sol",
  "IGatewayVotePreparation.sol",
  "AdminFunctions.s.sol",
  "DeployGatewayTransactionFilterer.s.sol",
  "IAdminFunctions.sol",
  "IDeployCTM.sol",
  "IDeployL1CoreContracts.sol",
  "IDeployGatewayTransactionFilterer.sol",
  "IGatewayUtils.sol",
  "GatewayUtils.s.sol",
  "IRegisterCTM.sol",
  "IRegisterOnAllChains.sol",
  "IFinalizeChainInit.sol",
  "ICoreUpgrade.sol",
  "ICoreUpgradeV33.sol",
  "ICTMUpgrade.sol",
  "IRecordPriorityOpLowerBound.sol",
  "IFinalizeUpgrade.sol",
  "CoreUpgrade_v33.s.sol",
  "IL1NativeTokenVault.sol",
  "IL2NativeTokenVault.sol",
  "IL1AssetRouter.sol",
  "IL2AssetRouter.sol",
  "IL2AssetTracker.sol",
  "IChainAdmin.sol",
  "DefaultUpgrade.sol",
  // Used by anvil-interop test suite (contracts.ts)
  "DummyInteropRecipient.sol",
  "L2Bridgehub.sol",
  "InteropCenter.sol",
  "IL1Bridgehub.sol",
  "L2AssetRouter.sol",
  "L2NativeTokenVault.sol",
  "L2NativeTokenVaultDev.sol",
  "L2AssetTracker.sol",
  "Executor.sol",
  "IServerNotifier.sol",
  "L1NativeTokenVault.sol",
  "TestnetERC20Token.sol",
  "L1AssetRouter.sol",
  "L2InteropHandler.sol",
  "IERC7786Attributes.sol",
  "L2ComplexUpgrader.sol",
  "L2GenesisUpgrade.sol",
  "L2MessageRoot.sol",
  "Mailbox.sol",
  "SystemContext.sol",
  "Ownable2Step.sol",
  "DummyL1MessageRoot.sol",
  "Migrator.sol",
  "L1Nullifier.sol",
  "L1InteropHandler.sol",
  "BaseTokenHolder.sol",
  // L1-free atomic interop (bundle model) — used by the anvil-interop atomic spec / CLI.
  "AtomicFlowManager.sol",
  "IAtomicFlowManager.sol",
  "L2InteropCommitmentTree.sol",
];

async function copyContractAbi(src: string, dest: string): Promise<number> {
  await fs.mkdir(dest, { recursive: true });
  const entries = await fs.readdir(src, { withFileTypes: true });
  let abiCount = 0;

  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      abiCount += await copyContractAbi(srcPath, destPath);
    } else if (entry.name.endsWith(".json")) {
      // Read the JSON file and reduce it to ABI-only JSON.
      const content = await fs.readFile(srcPath, "utf-8");
      const json = JSON.parse(content);

      if (json.abi) {
        await fs.writeFile(destPath, JSON.stringify(json.abi, null, 2));
        abiCount += 1;
      } else {
        throw new Error(`No ABI found in ${srcPath}`);
      }
    } else {
      // Copy non-JSON files as-is
      await fs.copyFile(srcPath, destPath);
    }
  }
  return abiCount;
}

async function main() {
  const l1ContractsDir = path.resolve(__dirname, "..");
  const outDir = path.join(l1ContractsDir, "out");
  const zkstackOutDir = path.join(l1ContractsDir, "zkstack-out");
  const stagingDir = path.join(l1ContractsDir, "zkstack-out.tmp");

  console.log("Copying contract ABIs to zkstack-out...");

  // Build a complete replacement separately so a malformed artifact cannot leave the committed
  // output half-rewritten. Only swap it into place after every ABI has been extracted successfully.
  await fs.rm(stagingDir, { recursive: true, force: true });
  await fs.mkdir(stagingDir, { recursive: true });
  try {
    for (const contract of REQUIRED_CONTRACTS) {
      const srcPath = path.join(outDir, contract);
      const destPath = path.join(stagingDir, contract);
      if ((await copyContractAbi(srcPath, destPath)) === 0) {
        throw new Error(`No ABI artifacts found in ${srcPath}`);
      }
      console.log(`Copied ${contract}`);
    }
  } catch (error) {
    await fs.rm(stagingDir, { recursive: true, force: true });
    throw error;
  }

  await fs.rm(zkstackOutDir, { recursive: true, force: true });
  await fs.rename(stagingDir, zkstackOutDir);

  console.log("Done copying contract ABIs to zkstack-out");
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});

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
  "IChainTypeManagerForZKStack.sol",
  "IValidatorTimelockForZKStack.sol",
  "IChainAssetHandler.sol",
  "IChainTypeManager.sol",
  "IAdmin.sol",
  "IDiamondCut.sol",
  "IChainAdminOwnable.sol",
  "IRegisterZKChain.sol",
  "IDeployL2Contracts.sol",
  "DeployPaymaster.s.sol",
  "IDeployPaymaster.sol",
  "GatewayVotePreparation.s.sol",
  "AdminFunctions.s.sol",
  "EnableEvmEmulator.s.sol",
  "DeployGatewayTransactionFilterer.s.sol",
  "IAdminFunctions.sol",
  "IEnableEvmEmulator.sol",
  "IDeployCTM.sol",
  "IDeployL1CoreContracts.sol",
  "IDeployGatewayTransactionFilterer.sol",
  "IGatewayUtils.sol",
  "GatewayUtils.s.sol",
  "IRegisterCTM.sol",
  "IRegisterOnAllChains.sol",
  "IGatewayMigrateTokenBalances.sol",
  "IFinalizeUpgrade.sol",
  "IL2NativeTokenVault.sol",
  "IL2AssetRouter.sol",
  "IAssetTrackerBase.sol",
  "IL2AssetTracker.sol",
  "IChainAdmin.sol",
  "ISetupLegacyBridge.sol",
];

async function copyContractAbi(src: string, dest: string): Promise<void> {
  await fs.mkdir(dest, { recursive: true });
  const entries = await fs.readdir(src, { withFileTypes: true });

  for (const entry of entries) {
    const srcPath = path.join(src, entry.name);
    const destPath = path.join(dest, entry.name);

    if (entry.isDirectory()) {
      await copyContractAbi(srcPath, destPath);
    } else if (entry.name.endsWith(".json")) {
      // Read the JSON file, extract the ABI, and write it back
      const content = await fs.readFile(srcPath, "utf-8");
      const json = JSON.parse(content);

      // Extract just the ABI field
      if (json.abi) {
        await fs.writeFile(destPath, JSON.stringify(json.abi, null, 2));
      } else {
        console.warn(`Warning: No ABI found in ${srcPath}`);
      }
    } else {
      // Copy non-JSON files as-is
      await fs.copyFile(srcPath, destPath);
    }
  }
}

async function main() {
  const l1ContractsDir = path.resolve(__dirname, "..");
  const outDir = path.join(l1ContractsDir, "out");
  const zkstackOutDir = path.join(l1ContractsDir, "zkstack-out");

  console.log("Copying contract ABIs to zkstack-out...");

  // Create zkstack-out directory if it doesn't exist
  await fs.mkdir(zkstackOutDir, { recursive: true });

  // Copy each required contract directory, extracting ABIs from JSON files
  for (const contract of REQUIRED_CONTRACTS) {
    const srcPath = path.join(outDir, contract);
    const destPath = path.join(zkstackOutDir, contract);

    try {
      await fs.access(srcPath);
      await copyContractAbi(srcPath, destPath);
      console.log(`Copied ${contract}`);
    } catch (error) {
      console.warn(`Warning: ${contract} not found in out`);
    }
  }

  console.log("Done copying contract ABIs to zkstack-out");
}

main().catch((error) => {
  console.error("Error:", error);
  process.exit(1);
});

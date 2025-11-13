// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars

import { Command } from "commander";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { web3Provider } from "./utils";

const provider = web3Provider();

const REQUIRED_BYTECODES: string[] = [
    "SystemContractProxy",
    "SystemContractProxyAdmin",
    "L2ComplexUpgrader",
    "L2MessageRoot",
    "L2Bridgehub",
    "L2AssetRouter",
    "L2NativeTokenVault",
    "L2ChainAssetHandler",
    "UpgradeableBeaconDeployer"
] as const;

const PUBLISHED_BYTECODES_REGISTRY_ABI = [
  "function bytecodeHashToDeployedAddress(bytes32) view returns (address)",
];

interface AllContractsHashesEntry {
  contractName: string;
  zkBytecodeHash: string | null;
  zkBytecodePath: string | null;
  evmBytecodeHash: string | null;
  evmBytecodePath: string | null;
  evmDeployedBytecodeHash: string | null;
}

async function loadAllContractsHashes(): Promise<AllContractsHashesEntry[]> {
  const jsonPath = path.join(__dirname, "..", "..", "AllContractsHashes.json");
  const fileContent = await fs.promises.readFile(jsonPath, "utf8");
  return JSON.parse(fileContent) as AllContractsHashesEntry[];
}

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("verify-bytecodes")
    .description("Verify that L1 contracts' deployed bytecodes are registered in PublishedBytecodesRegistry");

  program
    .requiredOption(
      "--registry-address <address>",
      "Address of the PublishedBytecodesRegistry contract"
    )
    .action(async (cmd) => {
      const registryAddress: string = cmd.registryAddress;

      const allContractsHashes = await loadAllContractsHashes();

      const registry = new ethers.Contract(
        registryAddress,
        PUBLISHED_BYTECODES_REGISTRY_ABI,
        provider
      );

      const failed: string[] = [];

      console.log(`Using PublishedBytecodesRegistry at: ${registryAddress}`);
      console.log(
        `Loaded ${allContractsHashes.length} entries from AllContractsHashes.json`
      );
      console.log("-------------------------------------------------------");

      for (const contractName of REQUIRED_BYTECODES) {
        const fullName = `l1-contracts/${contractName}`;
        const entry = allContractsHashes.find(
          (item) => item.contractName === fullName
        );

        console.log(`Contract: ${contractName} (full name: ${fullName})`);

        if (!entry) {
          console.error(
            `  ❌ No entry found in AllContractsHashes.json for "${fullName}"`
          );
          failed.push(contractName);
          console.log("");
          continue;
        }

        if (!entry.evmDeployedBytecodeHash) {
          console.error(
            `  ❌ evmDeployedBytecodeHash is null for "${fullName}" in AllContractsHashes.json`
          );
          failed.push(contractName);
          console.log("");
          continue;
        }

        const hash = entry.evmDeployedBytecodeHash;
        console.log(`  evmDeployedBytecodeHash: ${hash}`);

        const onChainAddress: string =
          await registry.bytecodeHashToDeployedAddress(hash);

        const isRegistered =
          onChainAddress &&
          onChainAddress.toLowerCase() !==
            ethers.constants.AddressZero.toLowerCase();

        if (isRegistered) {
          console.log(`  ✅ Registered at address: ${onChainAddress}`);
        } else {
          console.error(
            "  ❌ Not registered in PublishedBytecodesRegistry (zero address returned)"
          );
          failed.push(contractName);
        }

        console.log("");
      }

      if (failed.length > 0) {
        console.error(
          `Verification failed for contracts: ${failed.join(", ")}`
        );
        process.exitCode = 1;
      } else {
        console.log(
          "All contracts successfully found in PublishedBytecodesRegistry ✅"
        );
        process.exitCode = 0;
      }
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });

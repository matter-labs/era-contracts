import * as fs from "fs";
import * as path from "path";
import * as blakejs from "blakejs";
import { Command } from "commander";

/** Loads a Foundry artifact from /out/<name>.sol/<name>.json */
function loadArtifact(name: string) {
  const artifactPath = path.join(__dirname, `../out/${name}.sol/${name}.json`);
  const data = fs.readFileSync(artifactPath, "utf-8");
  return JSON.parse(data);
}

/** Extracts deployedBytecode.runtime from artifact */
function loadDeployedBytecode(name: string): string {
  const artifact = loadArtifact(name);
  return artifact.deployedBytecode.object; // runtime bytecode
}

// Helper to convert a hex string to Uint8Array
function hexToBytes(hex: string): Uint8Array {
  if (hex.startsWith("0x")) hex = hex.slice(2);
  if (hex.length % 2 !== 0) {
    throw new Error("Invalid hex string");
  }
  const bytes = new Uint8Array(hex.length / 2);
  for (let i = 0; i < bytes.length; i++) {
    bytes[i] = parseInt(hex.slice(i * 2, i * 2 + 2), 16);
  }
  return bytes;
}

async function main() {
  const program = new Command();
  program
    .version("0.1.0")
    .name("write-factory-deps-zksync-os")
    .description("Write zksync-os contract bytecodes and hashes")
    .option("--output <output>", "Path to output JSON file", path.join(__dirname, "zksync-os-bytecode-hashes.json"))
    .action(async (cmd) => {
      const contractNames = [
        "SystemContractProxy",
        "SystemContractProxyAdmin",
        "L2ComplexUpgrader",
        "L2MessageRoot",
        "L2Bridgehub",
        "L2AssetRouter",
        "L2NativeTokenVaultZKOS",
        "L2ChainAssetHandler",
        "UpgradeableBeaconDeployer",
        "L2V30TestnetSystemProxiesUpgrade",
      ];

      const output: Record<string, { bytecode_hash: string; bytecode: string }> = {};
      for (const name of contractNames) {
        const bytecode = loadDeployedBytecode(name);
        const bytecodeBytes = hexToBytes(bytecode);
        const hash = blakejs.blake2sHex(bytecodeBytes);
        output[name] = {
          // Snake-case for easier rust parsing.
          bytecode_hash: hash,
          bytecode: bytecode,
        };
        console.log(`${name}: ${hash}`);
      }

      fs.writeFileSync(cmd.output, JSON.stringify(output, null, 2));
      console.log(`Contract bytecodes and hashes written to ${cmd.output}`);
    });

  await program.parseAsync(process.argv);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

import { Command } from "commander";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { parse } from "toml";

// Transaction format expected by matter-labs/transaction-simulator
interface Transaction {
  network: string;
  from: string;
  to: string;
  data: string;
  value: string;
  tag: string;
  valueToMint?: string;
  timeIncrease?: string;
  description?: string;
}

const CALLS_ABI_TYPE = "tuple(address target, uint256 value, bytes data)[]";

// Known function selectors for human-readable descriptions
const KNOWN_SELECTORS: Record<string, string> = {
  "0xac700e63": "pauseMigration",
  "0xa39f7449": "checkUpgradeReadiness",
  "0x43bf9936": "checkUpgradeStarted",
  "0x386584cf": "checkUpgradeStageValidatorExists",
  "0x9b016b8b": "setChainCreationParams",
  "0x2e522851": "setNewVersionUpgrade",
  "0x37076ce3": "finishUpgrade",
  "0xf7c7eb92": "unpauseMigration",
  "0x407a5a0b": "cleanupAfterUpgrade",
};

function decodeCalls(data: string): Array<{ target: string; value: string; data: string }> {
  const coder = new ethers.utils.AbiCoder();
  const decoded = coder.decode([CALLS_ABI_TYPE], data);
  return decoded[0].map((call: any) => ({
    target: call.target,
    value: call.value.toString(),
    data: call.data,
  }));
}

function describeCall(to: string, data: string): string {
  const selector = data.substring(0, 10);
  const name = KNOWN_SELECTORS[selector];
  if (name) return name;
  return `call ${selector} on ${to}`;
}

async function main() {
  const program = new Command();

  program
    .name("generate-transaction-simulator-json")
    .description("Generate transaction-simulator JSON from forge ecosystem output TOML")
    .requiredOption("--ecosystem-output <path>", "Path to ecosystem output TOML from forge")
    .requiredOption("--env <environment>", "Environment: stage or mainnet")
    .option("--output <path>", "Output JSON file path (default: auto-generated)")
    .option("--upgrade-name <name>", "Upgrade name for the filename", "verifier-upgrade");

  program.parse(process.argv);
  const opts = program.opts();

  const envName = opts.env as string;

  // Determine network name for transaction-simulator
  let network: string;
  if (envName === "stage") {
    network = "sepolia";
  } else if (envName === "mainnet") {
    network = "mainnet";
  } else {
    console.error(`Unknown environment: ${envName}`);
    process.exit(1);
  }

  // Read ecosystem output TOML
  const tomlContent = fs.readFileSync(opts.ecosystemOutput, "utf8");
  const toml = parse(tomlContent);

  const ownerAddress = toml.owner_address;
  if (!ownerAddress) {
    console.error("Error: owner_address not found in ecosystem output TOML");
    process.exit(1);
  }

  console.log(`Environment: ${envName}`);
  console.log(`Network: ${network}`);
  console.log(`Owner (from): ${ownerAddress}`);

  const transactions: Transaction[] = [];

  // Decode and create transactions for each stage
  const stages = [
    { key: "stage0_calls", tag: "stage0" },
    { key: "stage1_calls", tag: "stage1" },
    { key: "stage2_calls", tag: "stage2" },
  ];

  for (const stage of stages) {
    const rawCalls = toml.governance_calls?.[stage.key];
    if (!rawCalls || rawCalls === "0x") {
      console.log(`  ${stage.tag}: no calls`);
      continue;
    }

    const calls = decodeCalls(rawCalls);
    console.log(`  ${stage.tag}: ${calls.length} calls`);

    for (let i = 0; i < calls.length; i++) {
      const call = calls[i];
      const tx: Transaction = {
        network,
        from: ownerAddress,
        to: call.target,
        data: call.data,
        value: call.value,
        tag: stage.tag,
      };

      // Add valueToMint on first tx of stage0 so the sender has ETH in simulation
      if (stage.tag === "stage0" && i === 0) {
        tx.valueToMint = "1000";
      }

      // Add description
      tx.description = describeCall(call.target, call.data);

      transactions.push(tx);
    }
  }

  console.log(`\nTotal transactions: ${transactions.length}`);

  // Determine output path
  const date = new Date().toISOString().split("T")[0]; // YYYY-MM-DD
  const defaultFilename = `${date}-${opts.upgradeName}-${envName}.json`;
  const outputPath = opts.output || path.join(".", defaultFilename);

  fs.writeFileSync(outputPath, JSON.stringify(transactions, null, 4) + "\n");
  console.log(`Written to: ${outputPath}`);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error(err);
    process.exit(1);
  });

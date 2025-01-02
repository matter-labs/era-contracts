/// Temporary script that generated the needed calldata for the migration of the governance.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import { Command } from "commander";
import { BigNumber, ethers, Wallet } from "ethers";

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-new-generator");

  program
    .option("--bridgehub-address <bridgehub-address>")
    .option("--era-chain-id <era-chain-id>")
    .option("--testnet-verifier <testnet-verifier>")
    .action(async (cmd) => {

    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });

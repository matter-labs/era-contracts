/// This is the script to double check the consistency of the upgrade
/// It is yet to be refactored.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { web3Url } from "./utils";
import { ethers } from "ethers";
import { Provider, utils } from "zksync-ethers";

// Things that still have to be manually double checked:
// 1. Contracts must be verified.
// 2. Getter methods in STM.

// List the contracts that should become the upgrade targets
const l2BridgeImplAddr = ''

const l2Provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);

async function checkIdenticalBytecode(addr: string, contract: string) {
  const correctCode = (await hardhat.artifacts.readArtifact(contract)).deployedBytecode;
  const currentCode = await l2Provider.getCode(addr);

  if (ethers.utils.keccak256(currentCode) == ethers.utils.keccak256(correctCode)) {
    console.log(contract, 'bytecode is correct');
  } else {
    throw new Error(contract + ' bytecode is not correct');
  }
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-consistency-checker").description("upgrade shared bridge for era diamond proxy");

  program
    .action(async (cmd) => {
      await checkIdenticalBytecode(l2BridgeImplAddr, 'GenesisUpgrade');
    });


  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });

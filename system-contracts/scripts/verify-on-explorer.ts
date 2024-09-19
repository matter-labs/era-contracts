// hardhat import should be the first import in the file
import * as hre from "hardhat";

import type { YulContractDescription } from "./constants";
import { SYSTEM_CONTRACTS } from "./constants";
import { query } from "./utils";
import { Command } from "commander";
import * as fs from "fs";
import { sleep } from "zksync-ethers/build/utils";

const VERIFICATION_URL = hre.network?.config?.verifyURL;

async function waitForVerificationResult(requestId: number) {
  let retries = 0;

  // eslint-disable-next-line no-constant-condition
  while (true) {
    if (retries > 50) {
      throw new Error("Too many retries");
    }

    const statusObject = await query("GET", `${VERIFICATION_URL}/${requestId}`);

    if (statusObject.status == "successful") {
      break;
    } else if (statusObject.status == "failed") {
      throw new Error(statusObject.error);
    } else {
      retries += 1;
      await sleep(1000);
    }
  }
}

async function verifyYul(contractInfo: YulContractDescription) {
  const sourceCodePath = `${__dirname}/../contracts-preprocessed/${contractInfo.path}/${contractInfo.codeName}.yul`;
  const sourceCode = (await fs.promises.readFile(sourceCodePath)).toString();
  const requestBody = {
    contractAddress: contractInfo.address,
    contractName: contractInfo.codeName,
    sourceCode: sourceCode,
    codeFormat: "yul-single-file",
    compilerZksolcVersion: hre.config.zksolc.version,
    compilerSolcVersion: hre.config.solidity.compilers[0].version,
    optimizationUsed: true,
    constructorArguments: "0x",
    isSystem: true,
  };

  const requestId = await query("POST", VERIFICATION_URL, undefined, requestBody);
  await waitForVerificationResult(requestId);
}

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("verify on explorer")
    .description("Verify system contracts source code on block explorer");

  for (const contractName in SYSTEM_CONTRACTS) {
    const contractInfo = SYSTEM_CONTRACTS[contractName];
    console.log(`Verifying ${contractInfo.codeName} on ${contractInfo.address} address..`);
    if (contractInfo.lang == "solidity") {
      await hre.run("verify:verify", {
        address: contractInfo.address,
        contract: `contracts-preprocessed/${contractInfo.codeName}.sol:${contractInfo.codeName}`,
        constructorArguments: [],
      });
    } else if (contractInfo.lang == "yul") {
      await verifyYul(contractInfo);
    } else {
      throw new Error("Unknown source code language!");
    }
  }

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });

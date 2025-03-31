// hardhat import should be the first import in the file

import type { SolidityContractDescription, YulContractDescription } from "./constants";
import { SourceLocation, SYSTEM_CONTRACTS } from "./constants";
import { query, spawn } from "./utils";
import { Command } from "commander";
import * as fs from "fs";
import { sleep } from "zksync-ethers/build/utils";

const VERIFICATION_URL = 'https://explorer.sepolia.era.zksync.dev/contract_verification';
const ZKSOLC_VERSION = 'v1.5.7';
const COMPILER_SOLC_VERSION = 'zkVM-0.8.24-1.0.1';

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

const CHAIN = 'zksync';

async function verifySolFoundry(contractInfo: SolidityContractDescription) {
  const codeNameWithPath = `contracts-preprocessed/${contractInfo.codeName}.sol:${contractInfo.codeName}`;
  await spawn(`forge verify-contract --zksync --chain ${CHAIN} --watch --verifier zksync --verifier-url ${VERIFICATION_URL} --constructor-args 0x ${contractInfo.address} ${codeNameWithPath}`);
}

async function verifyYul(contractInfo: YulContractDescription) {
  const sourceCodePath = `${__dirname}/../contracts-preprocessed/${contractInfo.path}/${contractInfo.codeName}.yul`;
  const sourceCode = (await fs.promises.readFile(sourceCodePath)).toString();
  const requestBody = {
    contractAddress: contractInfo.address,
    contractName: contractInfo.codeName,
    sourceCode: sourceCode,
    codeFormat: "yul-single-file",
    compilerZksolcVersion: ZKSOLC_VERSION,
    compilerSolcVersion: COMPILER_SOLC_VERSION,
    optimizationUsed: true,
    constructorArguments: "0x",
    isSystem: true,
  };

  try {
    const requestId = await query("POST", VERIFICATION_URL, undefined, requestBody);
    await waitForVerificationResult(requestId);
  } catch(e) {
    console.log(`Failed to process verification request. Error ${JSON.stringify(e)}`);
  }
}

async function main() {
  const program = new Command();

  program
    .version("0.1.0")
    .name("verify on explorer")
    .description("Verify system contracts source code on block explorer");

  for (const contractName in SYSTEM_CONTRACTS) {
    const contractInfo = SYSTEM_CONTRACTS[contractName];

    if (contractInfo.lang == 'solidity' && contractInfo.location == SourceLocation.L1Contracts) {
      console.log(`Skipped verification of ${contractInfo.codeName} since it is located in l1-contracts`);
      continue;
    }
  
    console.log(`Verifying ${contractInfo.codeName} on ${contractInfo.address} address..`);
    if (contractInfo.lang == "solidity") {
      if(contractInfo.location == SourceLocation.L1Contracts) {
        continue;
      }
  
      await verifySolFoundry(
        contractInfo
      );
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

// hardhat import should be the first import in the file

import type { SolidityContractDescription, YulContractDescription } from "./constants";
import { SourceLocation, SYSTEM_CONTRACTS } from "./constants";
import { query, spawn } from "./utils";
import { Command } from "commander";
import * as fs from "fs";
import { sleep } from "zksync-ethers/build/utils";
import { execFileSync } from "child_process";
import * as path from "path";
import { parseForgeCompilerInput, yulVerificationRequest } from "./yul-verification-input";

const VERIFICATION_URL = process.env.VERIFICATION_URL!;
// Require the exact fork release rather than guessing it from Solidity's semver.
// Different zkVM-solc patch releases can produce different bytecode.
const COMPILER_SOLC_VERSION = process.env.COMPILER_SOLC_VERSION;
const VERIFICATION_INPUT_DIR = process.env.VERIFICATION_INPUT_DIR;

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

const CHAIN = "zksync";

async function verifySolFoundry(contractInfo: SolidityContractDescription) {
  if (VERIFICATION_INPUT_DIR) {
    console.log(`Skipping Solidity submission in Yul input-export mode: ${contractInfo.codeName}`);
    return;
  }
  const codeNameWithPath = `contracts-preprocessed/${contractInfo.codeName}.sol:${contractInfo.codeName}`;
  await spawn(
    `forge verify-contract --zksync --chain ${CHAIN} --watch --verifier zksync --verifier-url ${VERIFICATION_URL} --constructor-args 0x ${contractInfo.address} ${codeNameWithPath}`
  );
}

async function verifyYul(contractInfo: YulContractDescription) {
  if (!COMPILER_SOLC_VERSION) throw new Error("Set COMPILER_SOLC_VERSION to the exact zkVM-solc release used to build");
  const sourceCodePath = path.posix.join("contracts-preprocessed", contractInfo.path, `${contractInfo.codeName}.yul`);
  const contractName = `${sourceCodePath}:${contractInfo.codeName}`;
  const config = JSON.parse(execFileSync("forge", ["config", "--json"], { encoding: "utf8" }));
  const compilerVersion = String(config.zksync.zksolc);
  const input = parseForgeCompilerInput(
    execFileSync(
      "forge",
      ["verify-contract", "--zksync", "--show-standard-json-input", contractInfo.address, contractName],
      { encoding: "utf8", maxBuffer: 32 * 1024 * 1024 }
    )
  );
  const requestBody = yulVerificationRequest(
    input,
    contractInfo.address,
    contractName,
    compilerVersion.startsWith("v") ? compilerVersion : `v${compilerVersion}`,
    COMPILER_SOLC_VERSION,
    config.zksync.llvm_options ?? []
  );
  if (VERIFICATION_INPUT_DIR) {
    await fs.promises.mkdir(VERIFICATION_INPUT_DIR, { recursive: true });
    await fs.promises.writeFile(
      path.join(VERIFICATION_INPUT_DIR, `${contractInfo.codeName}.json`),
      JSON.stringify(requestBody, null, 2)
    );
    console.log(`Exported ${contractInfo.codeName} verification input; no request submitted`);
    return;
  }

  try {
    const requestId = await query("POST", VERIFICATION_URL, undefined, requestBody);
    await waitForVerificationResult(requestId);
    console.log("Verification was successful.");
  } catch (e) {
    throw new Error(`Failed to verify ${contractInfo.codeName}: ${String(e)}`);
  }
}

async function main() {
  if (!VERIFICATION_INPUT_DIR && !VERIFICATION_URL) throw new Error("VERIFICATION_URL is required for submission");
  if (!COMPILER_SOLC_VERSION || !/^zkVM-\d+\.\d+\.\d+-\d+\.\d+\.\d+$/.test(COMPILER_SOLC_VERSION)) {
    throw new Error("Set COMPILER_SOLC_VERSION to the exact zkVM-solc release used to build before verification");
  }
  const program = new Command();

  program
    .version("0.1.0")
    .name("verify on explorer")
    .description("Verify system contracts source code on block explorer");

  for (const contractName in SYSTEM_CONTRACTS) {
    const contractInfo = SYSTEM_CONTRACTS[contractName];

    if (contractInfo.lang == "solidity" && contractInfo.location == SourceLocation.L1Contracts) {
      console.log(`Skipped verification of ${contractInfo.codeName} since it is located in l1-contracts`);
      continue;
    }

    console.log(`Verifying ${contractInfo.codeName} on ${contractInfo.address} address..`);
    if (contractInfo.lang == "solidity") {
      if (contractInfo.location == SourceLocation.L1Contracts) {
        continue;
      }

      await verifySolFoundry(contractInfo);
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

// hardhat import should be the first import in the file

import type { SolidityContractDescription, YulContractDescription } from "./constants";
import { SourceLocation, SYSTEM_CONTRACTS } from "./constants";
import { query, spawn } from "./utils";
import { Command } from "commander";
import * as fs from "fs";
import { sleep } from "zksync-ethers/build/utils";
import { execFileSync } from "child_process";
import * as path from "path";
import {
  compilerVersionsFromBytecode,
  parseForgeCompilerInput,
  yulVerificationRequest,
} from "./yul-verification-input";

const VERIFICATION_URL = process.env.VERIFICATION_URL!;
const VERIFICATION_INPUT_DIR = process.env.VERIFICATION_INPUT_DIR;
// Every Solidity artifact records the compilers of its build; SystemContext is always built.
const SOLIDITY_ARTIFACT = path.join(__dirname, "..", "zkout", "SystemContext.sol", "SystemContext.json");

interface YulCompilers {
  zksolc: string;
  solc: string;
  llvmOptions: string[];
}

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

// zksolc and the LLVM options come from the Foundry config. The zkVM-solc release is read from the
// build rather than guessed: Foundry picks the patch release implicitly, and patch releases produce
// different bytecode.
function yulCompilers(): YulCompilers {
  const config = JSON.parse(execFileSync("forge", ["config", "--json"], { encoding: "utf8" }));
  const configured = String(config.zksync.zksolc);
  const zksolc = configured.startsWith("v") ? configured : `v${configured}`;
  const built = compilerVersionsFromBytecode(JSON.parse(fs.readFileSync(SOLIDITY_ARTIFACT, "utf8")).bytecode.object);
  if (built.zksolc != zksolc) throw new Error(`zkout was built with zksolc ${built.zksolc}, the config pins ${zksolc}`);
  return { zksolc, solc: built.solc, llvmOptions: config.zksync.llvm_options ?? [] };
}

async function verifyYul(contractInfo: YulContractDescription, compilers: YulCompilers) {
  const sourceCodePath = path.posix.join("contracts-preprocessed", contractInfo.path, `${contractInfo.codeName}.yul`);
  const contractName = `${sourceCodePath}:${contractInfo.codeName}`;
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
    compilers.zksolc,
    compilers.solc,
    compilers.llvmOptions
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

  const requestId = await query("POST", VERIFICATION_URL, undefined, requestBody);
  await waitForVerificationResult(requestId);
  console.log("Verification was successful.");
}

// spawn() rejects with a string, and query() throws a plain { error, status } object when the
// response is not JSON.
function errorDetail(e: unknown): string {
  if (e instanceof Error) return e.message;
  return typeof e == "string" ? e : JSON.stringify(e);
}

async function main() {
  if (!VERIFICATION_INPUT_DIR && !VERIFICATION_URL) throw new Error("VERIFICATION_URL is required for submission");
  const compilers = yulCompilers();
  const program = new Command();

  program
    .version("0.1.0")
    .name("verify on explorer")
    .description("Verify system contracts source code on block explorer");

  // Attempt every contract and report all failures at the end, so one failure does not hide the rest.
  const succeeded: string[] = [];
  const failed: string[] = [];
  for (const contractName in SYSTEM_CONTRACTS) {
    const contractInfo = SYSTEM_CONTRACTS[contractName];

    if (contractInfo.lang == "solidity" && contractInfo.location == SourceLocation.L1Contracts) {
      console.log(`Skipped verification of ${contractInfo.codeName} since it is located in l1-contracts`);
      continue;
    }

    console.log(`Verifying ${contractInfo.codeName} on ${contractInfo.address} address..`);
    try {
      if (contractInfo.lang == "solidity") {
        if (contractInfo.location == SourceLocation.L1Contracts) {
          continue;
        }

        await verifySolFoundry(contractInfo);
      } else if (contractInfo.lang == "yul") {
        await verifyYul(contractInfo, compilers);
      } else {
        throw new Error("Unknown source code language!");
      }
      succeeded.push(contractInfo.codeName);
    } catch (e) {
      failed.push(`${contractInfo.codeName}: ${errorDetail(e)}`);
    }
  }

  // In input-export mode nothing is submitted: Yul requests are exported and Solidity ones skipped.
  const done = VERIFICATION_INPUT_DIR ? "Exported or skipped" : "Verified";
  console.log(`\n${done} (${succeeded.length}): ${succeeded.join(", ")}`);
  console.log(`Failed (${failed.length}):${failed.map((failure) => `\n  ${failure}`).join("")}`);
  if (failed.length > 0) throw new Error(`${failed.length} contract(s) failed`);

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });

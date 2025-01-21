import * as fs from "fs";
import { copyFileSync, existsSync, mkdirSync, writeFileSync } from "fs";
import path from "path";
import { glob } from "fast-glob";
import { Command } from "commander";
import { needsRecompilation, deleteDir, setCompilationTime, isFolderEmpty } from "./utils";

const CONTRACTS_DIR = "contracts";
const OUTPUT_DIR = "contracts-preprocessed";
const TIMESTAMP_FILE = "last_compilation_preprocessing.timestamp"; // File to store the last compilation time
const LLVM_OPTIONS_FILE_EXTENSION = ".llvm.options";

const params = {
  SYSTEM_CONTRACTS_OFFSET: "0x8000",
};

async function preprocess(testMode: boolean) {
  if (testMode) {
    console.log("\x1b[31mWarning: test mode for the preprocessing being used!\x1b[0m");
    params.SYSTEM_CONTRACTS_OFFSET = "0x9000";
  }
  const substring = "uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000;";
  const replacingSubstring = `uint160 constant SYSTEM_CONTRACTS_OFFSET = ${params.SYSTEM_CONTRACTS_OFFSET};`;

  const timestampFilePath = path.join(process.cwd(), TIMESTAMP_FILE);
  const folderToCheck = path.join(process.cwd(), CONTRACTS_DIR);

  if ((await isFolderEmpty(OUTPUT_DIR)) || needsRecompilation(folderToCheck, timestampFilePath) || testMode) {
    console.log("Preprocessing needed.");
    deleteDir(OUTPUT_DIR);
    setCompilationTime(timestampFilePath);
  } else {
    console.log("Preprocessing not needed.");
    return;
  }

  const contracts = await glob(
    [`${CONTRACTS_DIR}/**/*.sol`, `${CONTRACTS_DIR}/**/*.yul`, `${CONTRACTS_DIR}/**/*.zasm`],
    { onlyFiles: true }
  );

  for (const contractPath of contracts) {
    const contract = fs.readFileSync(contractPath, "utf8");
    const preprocessed = await contract.replace(substring, replacingSubstring);
    const fileName = `${OUTPUT_DIR}/${contractPath.slice(CONTRACTS_DIR.length)}`;
    const directory = path.dirname(fileName);
    if (!existsSync(directory)) {
      mkdirSync(directory, { recursive: true });
    }
    writeFileSync(fileName, preprocessed);
    if (existsSync(contract + LLVM_OPTIONS_FILE_EXTENSION)) {
      copyFileSync(contract + LLVM_OPTIONS_FILE_EXTENSION, fileName + LLVM_OPTIONS_FILE_EXTENSION);
    }
  }

  console.log("System Contracts preprocessing done!");
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("system contracts preprocessor").description("preprocess the system contracts");

  program.option("--test-mode").action(async (cmd) => {
    await preprocess(cmd.testMode);
  });

  await program.parseAsync(process.argv);
}

main();

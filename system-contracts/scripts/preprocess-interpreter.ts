import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";

/* eslint-disable @typescript-eslint/no-var-requires */
const preprocess = require("preprocess");
/* eslint-enable@typescript-eslint/no-var-requires */

const OUTPUT_DIR = "contracts/";

async function main() {
  process.chdir(`${OUTPUT_DIR}`);
  const interpreterSource = readFileSync(`EvmInterpreter.template.yul`).toString();

  console.log("Preprocessing Interpreter");
  const interpreter = preprocess.preprocess(interpreterSource);

  writeFileSync(`EvmInterpreter.yul`, interpreter);

  console.log("Intepreter preprocessing done!");
}

main();

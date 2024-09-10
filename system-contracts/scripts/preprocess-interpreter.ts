import { writeFileSync, readFileSync } from "fs";

/* eslint-disable @typescript-eslint/no-var-requires */
const preprocess = require("preprocess");
/* eslint-enable@typescript-eslint/no-var-requires */

const OUTPUT_DIR = "contracts";
const INPUT_DIR = "evm-interpreter";

async function main() {
  process.chdir(`${INPUT_DIR}`);
  const interpreterSource = readFileSync("EvmInterpreter.template.yul").toString();

  console.log("Preprocessing Interpreter");
  const interpreter = preprocess.preprocess(interpreterSource);

  writeFileSync(`../${OUTPUT_DIR}/EvmInterpreter.yul`, interpreter);

  console.log("Interpreter preprocessing done!");
}

main();

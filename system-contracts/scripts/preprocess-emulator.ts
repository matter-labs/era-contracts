import { writeFileSync, readFileSync } from "fs";

/* eslint-disable @typescript-eslint/no-var-requires */
const preprocess = require("preprocess");
/* eslint-enable@typescript-eslint/no-var-requires */

const OUTPUT_DIR = "contracts";
const INPUT_DIR = "evm-emulator";

async function main() {
  process.chdir(`${INPUT_DIR}`);
  const emulatorSource = readFileSync("EvmEmulator.template.yul").toString();

  console.log("Preprocessing Emulator");
  const emulator = preprocess.preprocess(emulatorSource);

  writeFileSync(`../${OUTPUT_DIR}/EvmEmulator.yul`, emulator);

  console.log("Emulator preprocessing done!");
}

main();

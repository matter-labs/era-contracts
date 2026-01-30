import fs from "fs";
import path from "path";
import { ethers } from "ethers";

const OUTPUT_DIR = "bootloader/artifacts";

const ARTIFACT_PATH = "zkout/{file}/Bootloader.json";

const bootloaderArtifacts = ["fee_estimate.yul", "gas_test.yul", "playground_batch.yul", "proved_batch.yul"];

bootloaderArtifacts.forEach((file) => {
  const filename = ARTIFACT_PATH.replace(/{file}/g, file);
  const filePath = path.join(__dirname, "..", filename);
  const outputFilePath = path.join(__dirname, "..", OUTPUT_DIR, `${path.basename(file, ".json")}.zbin`);

  const data = JSON.parse(fs.readFileSync(filePath, "utf-8"));

  if (data.bytecode && data.bytecode.object) {
    const bytecodeObject: string = data.bytecode.object;

    const bytecode = ethers.utils.arrayify(ethers.utils.hexlify(`0x${bytecodeObject}`));
    console.log(bytecode.length);

    if (!fs.existsSync(path.join(__dirname, OUTPUT_DIR))) {
      fs.mkdirSync(OUTPUT_DIR, { recursive: true });
      console.log(`Created directory ${OUTPUT_DIR}`);
    } else {
      console.log(`Directory ${OUTPUT_DIR} already exists`);
    }

    fs.writeFileSync(outputFilePath, bytecode);
    console.log(`Saved bytecode to ${outputFilePath}`);
  } else {
    console.error(`Invalid schema in ${file}: bytecode or object field is missing.`);
  }
});

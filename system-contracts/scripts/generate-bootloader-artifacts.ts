import fs from "fs";
import path from "path";

const OUTPUT_DIR = "bootloader/artifacts";

const ARTIFACT_PATH = "zkout/{file}/contracts-preprocessed/bootloader/{file}.json";

const bootloaderArtifacts = ["fee_estimate.yul", "gas_test.yul", "playground_batch.yul", "proved_batch.yul"];

bootloaderArtifacts.forEach((file) => {
  const filename = ARTIFACT_PATH.replace(/{file}/g, file);
  const filePath = path.join(__dirname, "..", filename);
  const outputFilePath = path.join(__dirname, "..", OUTPUT_DIR, `${path.basename(file, ".json")}.zbin`);

  const data = JSON.parse(fs.readFileSync(filePath, "utf-8"));

  if (data.bytecode && data.bytecode.object) {
    const bytecodeObject = data.bytecode.object;

    if (!fs.existsSync(path.join(__dirname, OUTPUT_DIR))) {
      fs.mkdirSync(OUTPUT_DIR, { recursive: true });
      console.log(`Created directory ${OUTPUT_DIR}`);
    } else {
      console.log(`Directory ${OUTPUT_DIR} already exists`);
    }

    fs.writeFileSync(outputFilePath, bytecodeObject, { flag: "w+" });
    console.log(`Saved bytecode to ${outputFilePath}`);
  } else {
    console.error(`Invalid schema in ${file}: bytecode or object field is missing.`);
  }
});

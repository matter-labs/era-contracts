#!/usr/bin/env ts-node

import * as fs from "fs/promises";
import { parse } from "toml";
import { stringify } from "yaml";

const RUN_FILE_PATH = process.env.UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS;
const OUTPUT_FILE_PATH = process.env.UPGRADE_ECOSYSTEM_OUTPUT;
const YAML_OUTPUT_FILE = process.env.YAML_OUTPUT_FILE;

// Utility function to safely parse JSON.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function readJSON(filePath: string): Promise<any> {
  const data = await fs.readFile(filePath, "utf8");
  return JSON.parse(data);
}

// Utility function to safely read and parse TOML.
// eslint-disable-next-line @typescript-eslint/no-explicit-any
async function readTOML(filePath: string): Promise<any> {
  const data = await fs.readFile(filePath, "utf8");
  return parse(data);
}

async function main() {
  // Read and parse the JSON run file.
  let runJson;
  try {
    runJson = await readJSON(RUN_FILE_PATH);
  } catch (err) {
    console.error(`Error reading or parsing ${RUN_FILE_PATH}:`, err);
    process.exit(1);
  }

  // Extract hashes from the transactions array.
  // Assumes each transaction object has a `hash` property.
  const transactionsArray: string[] = runJson.transactions.map((tx) => tx.hash);

  // Read and parse the output file as TOML.
  let outputToml;
  try {
    outputToml = await readTOML(OUTPUT_FILE_PATH);
  } catch (err) {
    console.error(`Error reading or parsing ${OUTPUT_FILE_PATH}:`, err);
    process.exit(1);
  }

  // Add transactions array to the TOML object.
  // We do not update the file on disk, we simply add/merge the key.
  outputToml.transactions = transactionsArray;

  // Convert the final object into YAML and output it.
  const yamlOutput = stringify(outputToml, { lineWidth: -1 });
  await fs.writeFile(YAML_OUTPUT_FILE, yamlOutput);
  console.log(yamlOutput);
}

main().catch((err) => {
  console.error("Unexpected error: ", err);
  process.exit(1);
});

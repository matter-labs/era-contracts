#!/usr/bin/env ts-node

import * as fs from 'fs/promises';
import {parse} from 'toml';
import {stringify} from 'yaml';

const RUN_FILE_PATH = 'broadcast/EcosystemUpgrade.s.sol/11155111/run-latest.json';
const OUTPUT_FILE_PATH = 'script-out/gateway-upgrade-ecosystem.toml';

// Utility function to safely parse JSON.
async function readJSON(filePath: string): Promise<any> {
  const data = await fs.readFile(filePath, 'utf8');
  return JSON.parse(data);
}

// Utility function to safely read and parse TOML.
async function readTOML(filePath: string): Promise<any> {
  const data = await fs.readFile(filePath, 'utf8');
  return parse(data);
}

async function main() {
  // Read and parse the JSON run file.
  let runJson: any;
  try {
    runJson = await readJSON(RUN_FILE_PATH);
  } catch (err) {
    console.error(`Error reading or parsing ${RUN_FILE_PATH}:`, err);
    process.exit(1);
  }

  // Extract hashes from the transactions array.
  // Assumes each transaction object has a `hash` property.
  const transactionsArray: string[] = runJson.transactions.map((tx: any) => tx.hash);
  
  // Read and parse the output file as TOML.
  let outputToml: any;
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
  const yamlOutput = stringify(outputToml);
  console.log(yamlOutput);
}

main().catch((err) => {
  console.error('Unexpected error: ', err);
  process.exit(1);
});

#!/usr/bin/env ts-node

import * as fs from "fs/promises";
import * as path from "path";
import { parse } from "toml";
import { stringify } from "yaml";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required environment variable: ${name}`);
  }
  return value;
}

const RUN_FILE_PATH = requireEnv("UPGRADE_ECOSYSTEM_OUTPUT_TRANSACTIONS");
const OUTPUT_FILE_PATH = requireEnv("UPGRADE_ECOSYSTEM_OUTPUT");
const YAML_OUTPUT_FILE = requireEnv("YAML_OUTPUT_FILE");
const UPGRADE_SEMVER = requireEnv("UPGRADE_SEMVER");
const UPGRADE_NAME = requireEnv("UPGRADE_NAME");
const UPGRADE_ENV = requireEnv("UPGRADE_ENV");

async function parseArgs(): Promise<{ puvtRepo?: string }> {
  const args = process.argv.slice(2);
  let puvtRepo: string | undefined;

  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--puvt-repo" && args[i + 1]) {
      puvtRepo = args[i + 1];
      i++;
    }
  }

  if (puvtRepo) {
    const gitDir = path.join(puvtRepo, ".git");
    try {
      await fs.access(gitDir);
    } catch {
      console.error(`Error: --puvt-repo does not appear to be a git repository (no .git directory found at ${gitDir})`);
      process.exit(1);
    }
  }

  return { puvtRepo };
}

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
  const { puvtRepo } = await parseArgs();

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

  // Build output directory path and organize files
  const upgradeEcosystemOutputDir = path.join("upgrade-envs", `v${UPGRADE_SEMVER}-${UPGRADE_NAME}`, "output", UPGRADE_ENV);
  await fs.mkdir(upgradeEcosystemOutputDir, { recursive: true });

  const tomlDestPath = path.join(upgradeEcosystemOutputDir, `v${UPGRADE_SEMVER}-ecosystem.toml`);
  const yamlDestPath = path.join(upgradeEcosystemOutputDir, `v${UPGRADE_SEMVER}-ecosystem.yaml`);

  await fs.copyFile(OUTPUT_FILE_PATH, tomlDestPath);
  await fs.copyFile(YAML_OUTPUT_FILE, yamlDestPath);

  console.log(`Copied TOML from ${OUTPUT_FILE_PATH} to ${tomlDestPath}`);
  console.log(`Copied YAML from ${YAML_OUTPUT_FILE} to ${yamlDestPath}`);

  // Copy YAML to protocol-upgrade-verification-tool repo if provided
  if (puvtRepo) {
    const puvtDestDir = path.join(puvtRepo, "data", `v${UPGRADE_SEMVER}`, UPGRADE_ENV);
    const puvtDestPath = path.join(puvtDestDir, `v${UPGRADE_SEMVER}-ecosystem.yaml`);

    await fs.mkdir(puvtDestDir, { recursive: true });
    await fs.copyFile(yamlDestPath, puvtDestPath);

    console.log(`Copied YAML from ${yamlDestPath} to puvt repo: ${puvtDestPath}`);
  }
}

main().catch((err) => {
  console.error("Unexpected error: ", err);
  process.exit(1);
});
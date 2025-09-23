#!/usr/bin/env ts-node
/**
 * 📄 verify-contracts.ts
 *
 * Usage:
 *   ts-node verify-contracts.ts <log_file> [stage|testnet|mainnet]
 *
 * Reads a deployment log file, extracts forge verify-contract commands,
 * finds the correct .sol sources, and runs `forge verify-contract` with
 * retries and fallbacks.
 */

import { execFileSync, execSync } from "child_process";
import { readFileSync, existsSync } from "fs";
import * as path from "path";

const args = process.argv.slice(2);
if (args.length < 1) {
  console.error("❌ Error: Missing log file argument");
  console.error("Usage: verify-contracts.ts <log_file> [stage|testnet|mainnet]");
  process.exit(1);
}

const LOG_FILE = args[0];
const CHAIN = (args[1] || "stage").toLowerCase(); // default to stage

if (!existsSync(LOG_FILE)) {
  console.error(`❌ Error: File '${LOG_FILE}' not found.`);
  process.exit(1);
}

// ZKsync verifier URLs
const ZKSYNC_VERIFIER_URLS: Record<string, string> = {
  mainnet: "https://rpc-explorer-verify.era-gateway-mainnet.zksync.dev/contract_verification",
  stage: "https://rpc-explorer-verify.era-gateway-stage.zksync.dev/contract_verification",
  testnet: "https://rpc-explorer-verify.era-gateway-testnet.zksync.dev/contract_verification",
};

const VERIFIED: string[] = [];
const SKIPPED: string[] = [];

// -----------------------------
// Fallback name mappings
// -----------------------------
function fallbackFor(name: string): string[] {
  switch (name) {
    case "ExecutorFacet":
      return ["Executor"];
    case "AdminFacet":
      return ["Admin"];
    case "MailboxFacet":
      return ["Mailbox"];
    case "GettersFacet":
      return ["Getters"];
    case "VerifierFflonk":
      return ["L1VerifierFflonk", "L2VerifierFflonk"];
    case "VerifierPlonk":
      return ["L1VerifierPlonk", "L2VerifierPlonk"];
    case "Verifier":
      return ["DualVerifier", "TestnetVerifier"];
    default:
      return [];
  }
}

// -----------------------------
// Find contract file & project root
// -----------------------------
function findContractAndRoot(name: string): { solPath: string; root: string; resolvedName: string } | null {
  let solPath = "";
  let resolvedName = name;
  const repoRoot = path.resolve(__dirname, "../..");

  try {
    solPath = execFileSync(
      "find",
      [`${repoRoot}/l1-contracts`, `${repoRoot}/da-contracts`, "-type", "f", "-iname", `${name}.sol`],
      { encoding: "utf8" }
    )
      .split("\n")[0]
      .trim();
  } catch {
    solPath = "";
  }

  if (!solPath) {
    const fallbacks = fallbackFor(name);
    if (fallbacks.length > 0) {
      console.log(`🛠 Using fallbacks for ${name}: ${fallbacks.join(", ")}`);
      for (const alt of fallbacks) {
        try {
          solPath = execFileSync(
            "find",
            [`${repoRoot}/l1-contracts`, `${repoRoot}/da-contracts`, "-type", "f", "-iname", `${alt}.sol`],
            { encoding: "utf8" }
          )
            .split("\n")[0]
            .trim();
        } catch {
          solPath = "";
        }
        if (solPath) {
          console.log(`   ✅ Found ${alt}.sol for ${name}`);
          resolvedName = alt;
          break;
        }
      }
    }
  }

  if (!solPath) return null;

  // Start from the directory where the Solidity file was found
  let dir = path.dirname(solPath);

  // Walk up the directory tree until we either:
  //  - reach the root of the repository (l1-contracts or da-contracts),
  //  - or find a folder that contains foundry.toml (project root).
  while (
    dir !== "." &&
    dir !== `${repoRoot}/l1-contracts` &&
    dir !== `${repoRoot}/da-contracts` &&
    !existsSync(path.join(dir, "foundry.toml"))
  ) {
    // Move one level up
    dir = path.dirname(dir);
  }

  // If we climbed all the way up and still didn’t find foundry.toml,
  // assume the project root is just the contracts folder (l1-contracts or da-contracts).
  if (!existsSync(path.join(dir, "foundry.toml"))) {
    if (solPath.includes("/l1-contracts/")) {
      dir = path.join(repoRoot, "l1-contracts");
    } else if (solPath.includes("/da-contracts/")) {
      dir = path.join(repoRoot, "da-contracts");
    } else {
      throw new Error(
        "❌ Could not determine project root for " +
          solPath +
          ". Expected it to be inside l1-contracts or da-contracts, but no foundry.toml found."
      );
    }
  }

  return { solPath, root: dir, resolvedName };
}

// -----------------------------
// Run a single forge verify attempt
// -----------------------------
function tryVerify(addr: string, name: string, rest: string, root: string, isZksync: boolean): boolean {
  let cmd: string;

  if (isZksync) {
    const url = ZKSYNC_VERIFIER_URLS[CHAIN];
    if (!url) {
      console.error(`❌ Unsupported chain "${CHAIN}" for zksync verifier`);
      return false;
    }
    cmd = `forge verify-contract ${addr} ${name} ${rest} --verifier-url ${url} --zksync --watch`;
  } else {
    const chainFlag = CHAIN === "mainnet" ? "--chain mainnet" : "--chain sepolia";
    cmd = `forge verify-contract ${addr} ${name} ${rest} --etherscan-api-key "${process.env.ETHERSCAN_API_KEY}" ${chainFlag} --watch`;
  }

  // Build masked command for logging
  const redacted = "--etherscan-api-key [REDACTED]";
  const maskedCmd = cmd.replace(/--etherscan-api-key\s+"[^"]*"/, redacted);
  console.log(`▶️  (cd ${root} && ${maskedCmd})`);

  try {
    execSync(cmd, { cwd: root, stdio: "inherit", shell: "/bin/bash" });
    return true;
  } catch {
    return false;
  }
}

// -----------------------------
// Main Loop
// -----------------------------
const logContent = readFileSync(LOG_FILE, "utf8");
const lines = logContent.split("\n").filter((l) => l.includes("forge verify-contract"));

for (const raw of lines) {
  const match = raw.match(/forge\s+verify-contract\s+([^\s]+)\s+([^\s]+)(.*)/);
  if (!match) {
    console.log(`⚠️  Could not parse: ${raw}`);
    SKIPPED.push(raw);
    continue;
  }

  const addr = match[1];
  const name = match[2];
  const rest = match[3] || "";
  const isZksync = rest.includes("--verifier zksync");

  if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) {
    console.log(`⚠️  Parsed non-address '${addr}' — skipping`);
    SKIPPED.push(raw);
    continue;
  }

  if (!isZksync && !process.env.ETHERSCAN_API_KEY) {
    console.error("❌ ETHERSCAN_API_KEY must be set for non-zksync verifier logs");
    process.exit(1);
  }

  const found = findContractAndRoot(name);
  if (!found) {
    console.log(`⚠️  Could not find ${name}.sol (or fallback) — skipping`);
    SKIPPED.push(name);
    continue;
  }

  const { solPath, root, resolvedName } = found;
  console.log(`📂 ${resolvedName} found: ${solPath} (project root: ${root})`);

  let success = tryVerify(addr, resolvedName, rest, root, isZksync);

  if (!success && resolvedName !== name) {
    console.log(`🔁 Retry with original contract name: ${name}`);
    success = tryVerify(addr, name, rest, root, isZksync);
  }

  if (!success) {
    console.log("🔁 Final attempt with TransparentUpgradeableProxy");
    success = tryVerify(addr, "TransparentUpgradeableProxy", rest, root, isZksync);
  }

  if (success) {
    VERIFIED.push(success ? resolvedName : name);
  } else {
    console.log(`❌ Verification failed for ${name}`);
    SKIPPED.push(name);
  }
}

// -----------------------------
// Summary
// -----------------------------
console.log("\n📊 Verification Summary:");
console.log(`✅ Verified contracts: ${VERIFIED.length}`);
VERIFIED.forEach((c) => console.log(`  - ${c}`));

if (SKIPPED.length > 0) {
  console.log(`⚠️  Skipped/Failed: ${SKIPPED.length}`);
  SKIPPED.forEach((c) => console.log(`  - ${c}`));
  process.exit(1);
} else {
  console.log("🎉 All contracts verified successfully!");
}

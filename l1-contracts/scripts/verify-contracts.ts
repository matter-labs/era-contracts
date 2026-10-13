#!/usr/bin/env ts-node
/**
 * 📄 verify-contracts.ts
 *
 * Usage:
 *   yarn ts-node l1-contracts/scripts/verify-contracts.ts <log_file> [options]
 *
 * Options:
 *   -c, --chain <chain>    Target chain: stage | testnet | mainnet (default: stage)
 *
 * Reads a deployment log file, extracts forge verify-contract commands,
 * finds the correct .sol sources, and runs `forge verify-contract` with
 * retries and fallbacks.
 */

import { Command } from "commander";
import { execFileSync, execSync } from "child_process";
import { readFileSync, existsSync } from "fs";
import * as path from "path";

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
      return ["ZKsyncOSVerifier", "ZKsyncOSTestnetVerifier"];
    case "MigratorFacet":
      return ["Migrator"];
    case "CommitterFacet":
      return ["Committer"];
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
function tryVerify(chain: string, addr: string, name: string, rest: string, root: string): boolean {
  if (!process.env.ETHERSCAN_API_KEY) {
    console.error("❌ ETHERSCAN_API_KEY must be set");
    process.exit(1);
  }
  const chainFlag = chain === "mainnet" ? "--chain mainnet" : "--chain sepolia";
  const cmd = `forge verify-contract ${addr} ${name} ${rest} --etherscan-api-key "${process.env.ETHERSCAN_API_KEY}" ${chainFlag} --watch`;

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

async function main() {
  const program = new Command();

  program
    .name("verify-contracts")
    .description("Automates contract verification from deployment logs")
    .argument("<log_file>", "Path to deployment log containing forge verify-contract commands")
    .option("-c, --chain <chain>", "Target chain (stage|testnet|mainnet)", "stage")
    .action(async (logFile, options) => {
      const chain = (options.chain || "stage").toLowerCase();
      if (!existsSync(logFile)) {
        console.error(`❌ Error: File '${logFile}' not found.`);
        process.exit(1);
      }

      const VERIFIED: string[] = [];
      const SKIPPED: string[] = [];

      // -----------------------------
      // Main Loop
      // -----------------------------
      const logContent = readFileSync(logFile, "utf8");
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

        if (!/^0x[0-9a-fA-F]{40}$/.test(addr)) {
          console.log(`⚠️  Parsed non-address '${addr}' — skipping`);
          SKIPPED.push(raw);
          continue;
        }

        const found = findContractAndRoot(name);
        if (!found) {
          console.log(`⚠️  Could not find ${name}.sol (or fallback) — skipping`);
          SKIPPED.push(name);
          continue;
        }

        const { solPath, root, resolvedName } = found;
        console.log(`📂 ${resolvedName} found: ${solPath} (project root: ${root})`);

        let success = tryVerify(chain, addr, resolvedName, rest, root);
        if (!success && resolvedName !== name) {
          console.log(`🔁 Retry with original contract name: ${name}`);
          success = tryVerify(chain, addr, name, rest, root);
        }
        if (!success) {
          console.log("🔁 Final attempt with TransparentUpgradeableProxy");
          success = tryVerify(chain, addr, "TransparentUpgradeableProxy", rest, root);
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
    });

  // Currently parse would also work, but keeping async for future compatibility
  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err.message || err);
    process.exit(1);
  });

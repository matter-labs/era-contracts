/**
 * Compare two chain-state directories, ignoring non-deterministic Anvil fields.
 *
 * With FOUNDRY_PROFILE=anvil-interop (cbor_metadata=false), bytecode and CREATE2
 * addresses are fully deterministic. The only remaining non-deterministic fields are:
 *   - Block-level: timestamp, basefee, prevrandao, difficulty
 *   - Account balances: minor variations from basefee-dependent gas costs
 *   - blocks/transactions arrays: contain hashes derived from the above
 *
 * This script compares everything except those known volatile fields.
 *
 * Usage:
 *     npx ts-node compare-chain-states.ts <committed-dir> <generated-dir>
 *
 * Exit code 0 if states match, 1 if they differ.
 */

import * as fs from "fs";
import * as path from "path";

const IGNORED_BLOCK_FIELDS = new Set(["timestamp", "basefee", "difficulty", "prevrandao", "blob_excess_gas_and_price"]);

// Maximum allowed balance difference in wei (0.01 ETH) — covers gas cost variations
const BALANCE_TOLERANCE_WEI = BigInt("10000000000000000"); // 10^16

interface ChainStateAccount {
  nonce?: number;
  code?: string;
  storage?: Record<string, string>;
  balance?: string;
}

interface ChainStateData {
  block?: Record<string, unknown>;
  accounts?: Record<string, ChainStateAccount>;
}

function compareChainState(data1: ChainStateData, data2: ChainStateData, name: string): string[] {
  const diffs: string[] = [];

  // Block: compare only deterministic fields
  if (data1.block && data2.block) {
    const allKeys = new Set([...Object.keys(data1.block), ...Object.keys(data2.block)]);
    for (const k of [...allKeys].sort()) {
      if (IGNORED_BLOCK_FIELDS.has(k)) continue;
      if (data1.block[k] !== data2.block[k]) {
        diffs.push(`  ${name}: block.${k}: ${data1.block[k]} != ${data2.block[k]}`);
      }
    }
  }

  // Accounts
  const accs1 = data1.accounts || {};
  const accs2 = data2.accounts || {};
  const addrs1 = new Set(Object.keys(accs1));
  const addrs2 = new Set(Object.keys(accs2));

  for (const addr of [...addrs1].filter((a) => !addrs2.has(a)).sort()) {
    diffs.push(`  ${name}: account ${addr} missing in generated`);
  }
  for (const addr of [...addrs2].filter((a) => !addrs1.has(a)).sort()) {
    diffs.push(`  ${name}: account ${addr} missing in committed`);
  }

  const commonAddrs = [...addrs1].filter((a) => addrs2.has(a)).sort();
  for (const addr of commonAddrs) {
    const a1 = accs1[addr];
    const a2 = accs2[addr];

    if (a1.nonce !== a2.nonce) {
      diffs.push(`  ${name}: account ${addr} nonce: ${a1.nonce} != ${a2.nonce}`);
    }

    if (a1.code !== a2.code) {
      const c1 = a1.code || "";
      const c2 = a2.code || "";
      if (c1.length !== c2.length) {
        diffs.push(`  ${name}: account ${addr} code length: ${c1.length} != ${c2.length}`);
      } else {
        let pos = -1;
        for (let i = 0; i < c1.length; i++) {
          if (c1[i] !== c2[i]) {
            pos = i;
            break;
          }
        }
        diffs.push(`  ${name}: account ${addr} code differs at position ${pos}/${c1.length}`);
      }
    }

    const s1 = a1.storage || {};
    const s2 = a2.storage || {};
    if (JSON.stringify(s1) !== JSON.stringify(s2)) {
      const allSlots = [...new Set([...Object.keys(s1), ...Object.keys(s2)])].sort();
      const diffSlots = allSlots.filter((s) => s1[s] !== s2[s]);
      diffs.push(`  ${name}: account ${addr} storage differs in ${diffSlots.length} slot(s)`);
      for (const slot of diffSlots.slice(0, 5)) {
        diffs.push(`    slot ${slot}: ${s1[slot]} != ${s2[slot]}`);
      }
    }

    const b1Str: string = a1.balance || "0x0";
    const b2Str: string = a2.balance || "0x0";
    if (b1Str !== b2Str) {
      try {
        const b1 = BigInt(b1Str);
        const b2 = BigInt(b2Str);
        const diff = b1 > b2 ? b1 - b2 : b2 - b1;
        if (diff > BALANCE_TOLERANCE_WEI) {
          diffs.push(`  ${name}: account ${addr} balance differs significantly: ${b1Str} vs ${b2Str}`);
        }
      } catch {
        diffs.push(`  ${name}: account ${addr} balance: ${b1Str} != ${b2Str}`);
      }
    }
  }

  return diffs;
}

function compareJsonFiles(path1: string, path2: string, name: string): string[] {
  if (!fs.existsSync(path1)) return [`  Missing in committed: ${name}`];
  if (!fs.existsSync(path2)) return [`  Missing in generated: ${name}`];

  const data1: unknown = JSON.parse(fs.readFileSync(path1, "utf-8"));
  const data2: unknown = JSON.parse(fs.readFileSync(path2, "utf-8"));

  if (name.endsWith("addresses.json")) {
    if (JSON.stringify(data1) !== JSON.stringify(data2)) {
      const diffs = [`  ${name}: addresses differ`];
      const obj1 = data1 as Record<string, unknown>;
      const obj2 = data2 as Record<string, unknown>;
      const allKeys = new Set([...Object.keys(obj1), ...Object.keys(obj2)]);
      for (const key of allKeys) {
        if (JSON.stringify(obj1[key]) !== JSON.stringify(obj2[key])) {
          diffs.push(`    ${key}: ${JSON.stringify(obj1[key])} != ${JSON.stringify(obj2[key])}`);
        }
      }
      return diffs;
    }
    return [];
  }

  return compareChainState(data1 as ChainStateData, data2 as ChainStateData, name);
}

function main() {
  const args = process.argv.slice(2);
  if (args.length !== 2) {
    console.error("Usage: ts-node compare-chain-states.ts <committed-dir> <generated-dir>");
    process.exit(2);
  }

  const [committedDir, generatedDir] = args;
  for (const d of [committedDir, generatedDir]) {
    if (!fs.existsSync(d) || !fs.statSync(d).isDirectory()) {
      console.error(`Error: ${d} is not a directory`);
      process.exit(2);
    }
  }

  const allDiffs: string[] = [];

  for (const versionDir of fs.readdirSync(committedDir).sort()) {
    const committedVersion = path.join(committedDir, versionDir);
    const generatedVersion = path.join(generatedDir, versionDir);

    if (!fs.statSync(committedVersion).isDirectory()) continue;
    if (!fs.existsSync(generatedVersion) || !fs.statSync(generatedVersion).isDirectory()) {
      allDiffs.push(`Missing version directory in generated: ${versionDir}`);
      continue;
    }

    const allFiles = [
      ...new Set([
        ...fs.readdirSync(committedVersion).filter((f) => f.endsWith(".json")),
        ...fs.readdirSync(generatedVersion).filter((f) => f.endsWith(".json")),
      ]),
    ].sort();

    for (const filename of allFiles) {
      const p1 = path.join(committedVersion, filename);
      const p2 = path.join(generatedVersion, filename);
      allDiffs.push(...compareJsonFiles(p1, p2, `${versionDir}/${filename}`));
    }
  }

  if (allDiffs.length > 0) {
    console.log("Chain state differences found:");
    for (const d of allDiffs) {
      console.log(d);
    }
    process.exit(1);
  } else {
    console.log("Committed chain states are up to date");
    process.exit(0);
  }
}

main();

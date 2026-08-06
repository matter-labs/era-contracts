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
import * as zlib from "zlib";

// Read a chain-state file, transparently gunzipping the compressed `.json.gz`
// dumps (see deployment-runner.ts). `addresses.json` stays plain text.
function readStateJson(p: string): unknown {
  const buf = fs.readFileSync(p);
  if (p.endsWith(".gz") || (buf.length >= 2 && buf[0] === 0x1f && buf[1] === 0x8b)) {
    return JSON.parse(zlib.gunzipSync(buf).toString("utf-8"));
  }
  return JSON.parse(buf.toString("utf-8"));
}

// `number` is wall-clock-volatile under interval mining — see the drift note below.
const IGNORED_BLOCK_FIELDS = new Set([
  "number",
  "timestamp",
  "basefee",
  "difficulty",
  "prevrandao",
  "blob_excess_gas_and_price",
]);

// Maximum allowed balance difference in wei (0.01 ETH) — covers gas cost variations
const BALANCE_TOLERANCE_WEI = BigInt("10000000000000000"); // 10^16

// Interval mining (`--block-time 1`, needed so the interop relayers keep progressing) makes the
// number of L2 blocks produced wall-clock-dependent, so two identical runs differ ONLY in state
// that records the current L2 block/batch number. That drift is confined to the account and slots
// below (verified by diffing two fresh Linux generations). We ignore exactly these by explicit
// identity — NOT by value magnitude, since many real slots legitimately hold small integers.

// Accounts whose storage is a block/batch-indexed accumulator, so ~all of it legitimately drifts
// run-to-run — skip storage compare entirely. Two sources: the fixed L2MessageRoot predeploy
// (0x…010005; block-indexed roots, trees, batch counters), plus deployment-specific L1 contracts
// resolved by role from addresses.json (L1 messageRoot and every chain diamond proxy — see
// collectSkipStorageAccounts). The L1NativeTokenVault is NOT skipped wholesale; its single
// gas-dependent `bridgedOut[ETH]` slot is handled by GAS_DEPENDENT_VALUE_SLOTS. Everything not in
// this set is still storage-compared exactly.
const BLOCK_INDEXED_STORAGE_ACCOUNTS = new Set(["0x0000000000000000000000000000000000010005"]);

// Resolve the deployment-specific batch-indexed / fee-dependent L1 contracts by
// role from the committed addresses.json, unioned with the fixed set above.
function collectSkipStorageAccounts(versionDir: string): Set<string> {
  const skip = new Set(BLOCK_INDEXED_STORAGE_ACCOUNTS);
  const p = path.join(versionDir, "addresses.json");
  if (!fs.existsSync(p)) return skip;
  const a = JSON.parse(fs.readFileSync(p, "utf-8")) as {
    l1Addresses?: { messageRoot?: string };
    chainAddresses?: Array<{ diamondProxy?: string }>;
  };
  const add = (v: unknown) => {
    if (typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v)) skip.add(v.toLowerCase());
  };
  add(a.l1Addresses?.messageRoot);
  for (const c of a.chainAddresses ?? []) add(c.diamondProxy);
  return skip;
}

// Keccak-derived slots (collision-free across contracts) holding an L2 block/batch number in the
// interop bookkeeping contracts. These were the only common-slot value diffs between two fresh
// runs, each differing by exactly the block-count delta. Ignored in whichever account they appear.
const BLOCK_NUMBER_STORAGE_SLOTS = new Set([
  "0x22157c206018468b45ae7922bc7a0b0cb8feed201dac3c6fb5e7876aa94e11e9",
  "0xcae482817da5739a72d01cb9874e04d330e5e8dc74bc0bece220f5b3532c14b8",
  "0xe12917faa952038297cceeb966eb4f054126fd0f1307df22b19432454cb24b37",
  "0xa1a0bcd6e1eb10e34e86589f0737ed295f21e2780238b04598ea22e184199ff6",
]);

// Slots holding a gas-cost-dependent ETH amount (the harness bridges a gas-dependent mintValue on
// L1->L2 deposits): compared with BALANCE_TOLERANCE_WEI slack rather than skipped, so large (real)
// drift is still caught. Currently the L1NativeTokenVault's `bridgedOut[ETH]` entry:
//   slot = keccak256(abi.encode(ethAssetId, 208)), 208 = `bridgedOut` mapping storage index
//   (in NativeTokenVaultBase, taken from the base storage gap).
//   Recompute with `cast index bytes32 <ethAssetId> 208` if the NTV layout changes.
const GAS_DEPENDENT_VALUE_SLOTS = new Set(["0x80f3e2725fd7fa6d070f44bef74b22e264b19f41c5c0807061a63828cd8a7e66"]);

// True when two raw storage words differ by no more than the native-balance
// tolerance (used only for slots known to hold a gas-dependent ETH amount).
function withinBalanceTolerance(v1?: string, v2?: string): boolean {
  try {
    const a = BigInt(v1 ?? "0x0");
    const b = BigInt(v2 ?? "0x0");
    const diff = a > b ? a - b : b - a;
    return diff <= BALANCE_TOLERANCE_WEI;
  } catch {
    return false;
  }
}

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

function compareChainState(
  data1: ChainStateData,
  data2: ChainStateData,
  name: string,
  skipStorageAccounts: Set<string>
): string[] {
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

    // Skip storage for batch-indexed / fee-dependent contracts (MessageRoots,
    // chain diamonds): their state tracks the non-deterministic block count.
    if (!skipStorageAccounts.has(addr.toLowerCase())) {
      const s1 = a1.storage || {};
      const s2 = a2.storage || {};
      if (JSON.stringify(s1) !== JSON.stringify(s2)) {
        const allSlots = [...new Set([...Object.keys(s1), ...Object.keys(s2)])].sort();
        // Drop the explicitly-listed block-number slots (see above) and tolerate
        // gas-scale drift on the known gas-dependent value slots; everything else
        // must match exactly.
        const diffSlots = allSlots.filter((s) => {
          if (s1[s] === s2[s]) return false;
          if (BLOCK_NUMBER_STORAGE_SLOTS.has(s)) return false;
          if (GAS_DEPENDENT_VALUE_SLOTS.has(s) && withinBalanceTolerance(s1[s], s2[s])) return false;
          return true;
        });
        if (diffSlots.length > 0) {
          diffs.push(`  ${name}: account ${addr} storage differs in ${diffSlots.length} slot(s)`);
          for (const slot of diffSlots.slice(0, 5)) {
            diffs.push(`    slot ${slot}: ${s1[slot]} != ${s2[slot]}`);
          }
        }
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

function compareJsonFiles(path1: string, path2: string, name: string, skipStorageAccounts: Set<string>): string[] {
  if (!fs.existsSync(path1)) return [`  Missing in committed: ${name}`];
  if (!fs.existsSync(path2)) return [`  Missing in generated: ${name}`];

  const data1: unknown = readStateJson(path1);
  const data2: unknown = readStateJson(path2);

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

  return compareChainState(data1 as ChainStateData, data2 as ChainStateData, name, skipStorageAccounts);
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

    // Resolve batch-indexed / fee-dependent contracts (whose storage to skip)
    // by role from this version's committed addresses.json.
    const skipStorageAccounts = collectSkipStorageAccounts(committedVersion);

    const isStateFile = (f: string) => f.endsWith(".json") || f.endsWith(".json.gz");
    const allFiles = [
      ...new Set([
        ...fs.readdirSync(committedVersion).filter(isStateFile),
        ...fs.readdirSync(generatedVersion).filter(isStateFile),
      ]),
    ].sort();

    for (const filename of allFiles) {
      const p1 = path.join(committedVersion, filename);
      const p2 = path.join(generatedVersion, filename);
      allDiffs.push(...compareJsonFiles(p1, p2, `${versionDir}/${filename}`, skipStorageAccounts));
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

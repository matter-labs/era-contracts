/**
 * Compare two chain-state directories, ignoring non-deterministic Anvil fields.
 *
 * With FOUNDRY_PROFILE=anvil-interop (cbor_metadata=false), bytecode and CREATE2
 * addresses are fully deterministic. The remaining non-deterministic fields include:
 *   - Block-level: timestamp, basefee, prevrandao, difficulty
 *   - Account balances: minor variations from basefee-dependent gas costs
 *   - Priority-operation timestamps and gas-sensitive priority-tree hashes
 *   - blocks/transactions arrays: contain hashes derived from the above
 *
 * This script compares all accounts and the deterministic projection of chain-diamond storage.
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

// Interval mining (`--block-time 1`, needed so the interop relayers keep progressing) makes block
// progress and gas costs wall-clock-dependent. Ignore drift by storage identity or contract role,
// not by value magnitude, since many deterministic slots legitimately hold small integers.

// MessageRoot storage is a block/batch-indexed accumulator, so ~all of it legitimately drifts
// run-to-run. Chain diamonds are handled separately: their deterministic fixed-layout state and
// facet membership are compared, while their gas-sensitive priority-tree contents are not.
const BLOCK_INDEXED_STORAGE_ACCOUNTS = new Set(["0x0000000000000000000000000000000000010005"]);

interface StorageAccountPolicies {
  skip: Set<string>;
  diamonds: Set<string>;
}

// Resolve deployment-specific MessageRoot and chain-diamond addresses by role. Only MessageRoot is
// skipped wholesale; diamonds use the deterministic projection in isComparableDiamondSlot().
function collectStorageAccountPolicies(versionDir: string): StorageAccountPolicies {
  const skip = new Set(BLOCK_INDEXED_STORAGE_ACCOUNTS);
  const diamonds = new Set<string>();
  const p = path.join(versionDir, "addresses.json");
  if (!fs.existsSync(p)) return { skip, diamonds };
  const a = JSON.parse(fs.readFileSync(p, "utf-8")) as {
    l1Addresses?: { messageRoot?: string };
    chainAddresses?: Array<{ diamondProxy?: string }>;
  };
  const add = (set: Set<string>, v: unknown) => {
    if (typeof v === "string" && /^0x[0-9a-fA-F]{40}$/.test(v)) set.add(v.toLowerCase());
  };
  add(skip, a.l1Addresses?.messageRoot);
  for (const c of a.chainAddresses ?? []) add(diamonds, c.diamondProxy);
  return { skip, diamonds };
}

const ZK_CHAIN_FIXED_SLOT_COUNT = 69n;
const LAST_TOKEN_MULTIPLIER_UPDATE_TIMESTAMP_SLOT = 67n;
const GENESIS_STORED_BATCH_HASH_SLOT = "0xe710864318d4a32f37d6ce54cb3fadbef648dd12d8dbdf53973564d56b7f881c";
const DIAMOND_STORAGE_POSITION = BigInt("0xc8fcad8db84d3cc18b4c41d551ea0ee66dd599cde068d998e57d5e09332c131b");
const DIAMOND_FACETS_LENGTH_SLOT = DIAMOND_STORAGE_POSITION + 2n;
const DIAMOND_FROZEN_SLOT = DIAMOND_STORAGE_POSITION + 3n;
const DIAMOND_FACETS_ARRAY_START = BigInt("0xc0d727610ea16241eff4447d08bb1b4595f7d2ec4515282437a13b7d0df4b922");

function storageWord(storage: Record<string, string>, slot: bigint): bigint {
  const key = `0x${slot.toString(16).padStart(64, "0")}`;
  return BigInt(storage[key] ?? "0x0");
}

// Priority-operation timestamps, historical roots and Merkle-tree sides depend on interval-mining
// progress and gas-sensitive priority transactions. The fixed layout still covers protocol/config
// state and the tree's indices, sizes and array lengths. Facet membership and the genesis batch hash
// are deterministic and are compared as well.
function isComparableDiamondSlot(
  slot: string,
  committedStorage: Record<string, string>,
  generatedStorage: Record<string, string>
): boolean {
  let slotNumber: bigint;
  try {
    slotNumber = BigInt(slot);
  } catch {
    return true;
  }

  if (slotNumber < ZK_CHAIN_FIXED_SLOT_COUNT) {
    return slotNumber !== LAST_TOKEN_MULTIPLIER_UPDATE_TIMESTAMP_SLOT;
  }
  if (slot === GENESIS_STORED_BATCH_HASH_SLOT) return true;
  if (slotNumber === DIAMOND_FACETS_LENGTH_SLOT || slotNumber === DIAMOND_FROZEN_SLOT) return true;

  const facetCount = [
    storageWord(committedStorage, DIAMOND_FACETS_LENGTH_SLOT),
    storageWord(generatedStorage, DIAMOND_FACETS_LENGTH_SLOT),
  ].reduce((max, value) => (value > max ? value : max), 0n);
  return slotNumber >= DIAMOND_FACETS_ARRAY_START && slotNumber < DIAMOND_FACETS_ARRAY_START + facetCount;
}

// Keccak-derived slots (collision-free across contracts) holding an L2 block/batch number in the
// interop bookkeeping contracts. These were the only common-slot value diffs between two fresh
// runs, each differing by exactly the block-count delta. Ignored in whichever account they appear.
const BLOCK_NUMBER_STORAGE_SLOTS = new Set([
  "0x22157c206018468b45ae7922bc7a0b0cb8feed201dac3c6fb5e7876aa94e11e9",
  "0xcae482817da5739a72d01cb9874e04d330e5e8dc74bc0bece220f5b3532c14b8",
  "0xe12917faa952038297cceeb966eb4f054126fd0f1307df22b19432454cb24b37",
  "0xa1a0bcd6e1eb10e34e86589f0737ed295f21e2780238b04598ea22e184199ff6",
  // Appears on the L1 ChainTypeManager and one L2 bookkeeping contract. This check compares
  // committed against freshly generated state for the SAME tree, so a difference here can only be
  // run-to-run drift; observed as 44 -> 53 (L1) and 197 -> 222 (L2 chain 11), i.e. the block-count
  // delta between the two generations, matching the other entries in this set.
  "0xcbb92218c6fa6b4bbce0fd2138701a2aa354649a9f1f834c324c529c16aca477",
]);

// Slots holding a gas-cost-dependent ETH amount (the harness bridges a gas-dependent mintValue on
// L1->L2 deposits): compared with BALANCE_TOLERANCE_WEI slack rather than skipped, so large (real)
// drift is still caught. Currently the L1NativeTokenVault's `bridgedOut[ETH]` entry:
//   slot = keccak256(abi.encode(ethAssetId, 253)), 253 = `bridgedOut` mapping storage index.
//   Recompute with `cast index bytes32 <ethAssetId> 253` if the NTV layout changes.
const GAS_DEPENDENT_VALUE_SLOTS = new Set(["0xa779570f23bf75d0370baade00c3f15fe23265e729cfb55c61a10ccf98dc7093"]);

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
  storagePolicies: StorageAccountPolicies
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

    // MessageRoot is wholly block-indexed. Diamonds compare their deterministic projection; every
    // other account compares all storage except the explicit global drift slots below.
    if (!storagePolicies.skip.has(addr.toLowerCase())) {
      const s1 = a1.storage || {};
      const s2 = a2.storage || {};
      if (JSON.stringify(s1) !== JSON.stringify(s2)) {
        const allSlots = [...new Set([...Object.keys(s1), ...Object.keys(s2)])].sort();
        // Drop the explicitly-listed block-number slots (see above) and tolerate
        // gas-scale drift on the known gas-dependent value slots; everything else
        // must match exactly.
        const diffSlots = allSlots.filter((s) => {
          if (s1[s] === s2[s]) return false;
          if (storagePolicies.diamonds.has(addr.toLowerCase()) && !isComparableDiamondSlot(s, s1, s2)) return false;
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

function compareJsonFiles(
  path1: string,
  path2: string,
  name: string,
  storagePolicies: StorageAccountPolicies
): string[] {
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

  return compareChainState(data1 as ChainStateData, data2 as ChainStateData, name, storagePolicies);
}

export function compareStateDirectories(committedDir: string, generatedDir: string): string[] {
  const allDiffs: string[] = [];
  const listVersionDirs = (root: string) =>
    fs
      .readdirSync(root)
      .filter((entry) => fs.statSync(path.join(root, entry)).isDirectory())
      .sort();
  const committedVersions = listVersionDirs(committedDir);
  const generatedVersions = listVersionDirs(generatedDir);
  const committedVersionSet = new Set(committedVersions);
  const generatedVersionSet = new Set(generatedVersions);

  for (const versionDir of committedVersions.filter((entry) => !generatedVersionSet.has(entry))) {
    allDiffs.push(`Missing version directory in generated: ${versionDir}`);
  }
  for (const versionDir of generatedVersions.filter((entry) => !committedVersionSet.has(entry))) {
    allDiffs.push(`Missing version directory in committed: ${versionDir}`);
  }

  for (const versionDir of committedVersions.filter((entry) => generatedVersionSet.has(entry))) {
    const committedVersion = path.join(committedDir, versionDir);
    const generatedVersion = path.join(generatedDir, versionDir);

    const storagePolicies = collectStorageAccountPolicies(committedVersion);

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
      allDiffs.push(...compareJsonFiles(p1, p2, `${versionDir}/${filename}`, storagePolicies));
    }
  }

  return allDiffs;
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

  const allDiffs = compareStateDirectories(committedDir, generatedDir);

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

if (require.main === module) main();

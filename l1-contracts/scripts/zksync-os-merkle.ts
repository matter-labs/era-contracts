import { utils, BigNumber } from "ethers";

export interface BlakeLikeHasher {
  /** Blake2s256(key || value || next_index_le) */
  hashLeaf(key32: string, value32: string, nextIndex: number): string;
  /** Blake2s256(lhs || rhs) */
  hashBranch(lhs32: string, rhs32: string): string;
}

export function ensureHex32(x: string): string {
  if (typeof x !== "string") throw new Error(`Expected hex string, got ${x}`);
  if (x.length < 2 || !x.startsWith("0x")) throw new Error(`Expected hex string, got ${x}`);
  if (x.length !== 66) throw new Error(`Expected 32-byte hex, got ${x}`);
  return x.toLowerCase();
}

export function u64ToLeBytes(n: number): Uint8Array {
    if (!Number.isSafeInteger(n) || n < 0) {
        throw new Error("u64 out of range");
    }
    const a = new Uint8Array(8);
    let v = n;
    for (let i = 0; i < 8; i++) {
        a[i] = v & 0xff;
        v = Math.floor(v / 256);
    }
    return a;
}

export function u64ToBeBytes(n: number): Uint8Array {
    if (!Number.isSafeInteger(n) || n < 0) {
        throw new Error("u64 out of range");
    }
    const a = new Uint8Array(8);
    let v = n;
    for (let i = 7; i >= 0; i--) {
        a[i] = v & 0xff;
        v = Math.floor(v / 256);
    }
    return a;
}

type KV = [string, string];

type RootInfo = {
  rootHash: string;
  leafCount: number;
};

const ZERO32 = ("0x" + "00".repeat(32));
const FF32 = ("0x" + "ff".repeat(32));

/**
 * Compute the genesis Merkle root & leaf count, mirroring your hashing and padding rules.
 * - Adds guard leaves (0x00..00 and 0xff..ff with value=0) to the provided storage logs.
 * - Computes next_index for each sorted leaf (guards included).
 * - Hashes leaves: Blake2s256(key || value || next_index_le).
 * - Reduces for all `treeDepth` levels, padding the right-most orphan with `emptySubtreeHash(depth)`.
 */
export function computeGenesisMerkleRoot(
  storageLogs: KV[],
  hasher: BlakeLikeHasher,
  { treeDepth }: { treeDepth: number }
): RootInfo {
  if (storageLogs.length == 0) {
    throw new Error("At least one storage log is required to build the Merkle tree.");
  }

  // 1) Build sorted leaf set with guards.
  const sortedLogs: Array<{ key: string; value: string }> = [
    ...storageLogs.map(([k, v]) => ({ key: ensureHex32(k), value: ensureHex32(v) })),
  ].sort((a, b) => {
    const ka = BigNumber.from(a.key);
    const kb = BigNumber.from(b.key);
    return ka.lt(kb) ? -1 : ka.gt(kb) ? 1 : 0;
  });
  const treeLeaves = [
    { key: ZERO32, value: ZERO32 }, // MIN_GUARD
    { key: FF32, value: ZERO32 }, // MAX_GUARD
    ...sortedLogs
  ];
  
  // 2) Compute next_index per leaf (point to the next key in the fully built sorted list).
  const leafCount = treeLeaves.length;
  const leafHashes: string[] = new Array(leafCount);

  // The minimal leaf always points to the 2nd leaf.
  leafHashes[0] = hasher.hashLeaf(ZERO32, ZERO32, 2);
  // The maximal leaf always points to itself.
  leafHashes[1] = hasher.hashLeaf(FF32, ZERO32, 1);
  for (let i = 2; i < leafCount; i++) {
    const key = treeLeaves[i].key;
    const value = treeLeaves[i].value;
    const nextIndex = i + 1 < leafCount ? i + 1 : 1; // wrap for MAX_GUARD
    leafHashes[i] = hasher.hashLeaf(key, value, nextIndex);
  }

  // 3) Reduce bottom-up across ALL depths to reach a single root.
  let level = 0;
  let nodes = leafHashes.slice();
  let emptySubtreeHash = hasher.hashLeaf(ZERO32, ZERO32, 0); // empty leaf hash

  while (level < treeDepth) {
    const nextNodes: string[] = [];
    for (let i = 0; i < nodes.length; i += 2) {
      const lhs = nodes[i];
      const rhs = i + 1 < nodes.length ? nodes[i + 1] : emptySubtreeHash;
      nextNodes.push(hasher.hashBranch(lhs, rhs));
    }
    nodes = nextNodes;
    level += 1;
    emptySubtreeHash = hasher.hashBranch(emptySubtreeHash, emptySubtreeHash);
  }

  if (nodes.length !== 1) {
    // After `treeDepth` rounds we must have exactly one node.
    throw new Error(`Merkle reduction did not collapse to a single root (len=${nodes.length}).`);
  }

  return { rootHash: nodes[0], leafCount };
}

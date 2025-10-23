#!/usr/bin/env ts-node

/* eslint-disable no-console */

import { Command } from "commander";
import { utils, constants, BigNumberish, ethers, BigNumber } from "ethers";
import { blake2s } from "./utils";
import * as fs from "node:fs/promises";
import * as path from "node:path";
import {
  BlakeLikeHasher,
  computeGenesisMerkleRoot,
  ensureHex32,
  u64ToBeBytes,
  u64ToLeBytes,
} from "./zksync-os-merkle";

// ───────────────────────────────────────────────────────────────────────────────
// 1) CONSTANTS (as requested: file starts with initial_contracts mapping)
// ───────────────────────────────────────────────────────────────────────────────

/**
 * Mapping: L2 address -> contract name (you’ll implement how to load each name’s bytecode).
 * Feel free to rename these to your actual contracts — the names here are just placeholders.
 */
export const INITIAL_CONTRACTS: Record<string, string> = {
  "0x000000000000000000000000000000000000800f": "SystemContractProxy",
  "0x0000000000000000000000000000000000010001": "L2GenesisUpgrade",
  "0x0000000000000000000000000000000000010007": "L2WrappedBaseToken",
  "0x000000000000000000000000000000000001000c": "SystemContractProxyAdmin",
  "0x504c4af171d1b5f31c8b8f181c21484b75110f87": "L2ComplexUpgrader",
} as const;

/**
 * Keep “pretty” additional storage AS-IS (address -> slot -> value).
 * These will be flattened (you’ll provide the key derivation).
 */
export const ADDITIONAL_STORAGE: Record<string, Record<string, string>> = {
  "0x000000000000000000000000000000000001000c": {
    "0x0000000000000000000000000000000000000000000000000000000000000000":
      "0x000000000000000000000000000000000000000000000000000000000000800f",
  },
  "0x000000000000000000000000000000000000800f": {
    "0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc":
      "0x000000000000000000000000504c4af171d1b5f31c8b8f181c21484b75110f87",
    "0xb53127684a568b3173ae13b9f8a6016e243e63b6e8ee1178d6a717850b5d6103":
      "0x000000000000000000000000000000000000000000000000000000000001000c",
  },
} as const;

/** Keep “raw” additional storage AS-IS. */
export const ADDITIONAL_STORAGE_RAW: Array<[string, string]> = [];

/** Execution version constant. */
export const EXECUTION_VERSION = 3 as const;

export const ACCOUNT_PROPERTIES_STORAGE_ADDRESS = "0x0000000000000000000000000000000000008003";

export const EMPTY_OMMER_ROOT_HASH = '0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347';

// ───────────────────────────────────────────────────────────────────────────────
// 2) Black boxes you will implement (I keep their signatures/stubs here)
// ───────────────────────────────────────────────────────────────────────────────

/** Load EVM bytecode hex string for a named contract (must start with 0x). */
async function getBytecodeByContractName(_name: string): Promise<string> {
  const filePath = path.resolve(__dirname, `../out/${_name}.sol/${_name}.json`);

  const artifact = JSON.parse(
    await fs.readFile(filePath, "utf-8")
  );
  if (!artifact.deployedBytecode || !artifact.deployedBytecode.object || artifact.deployedBytecode.object === "0x") {
    throw new Error(`No deployed bytecode found in artifact for contract ${_name}`);
  }
  return artifact.deployedBytecode.object;
}

/**
 * Compute EVM "artifacts" (jumpdest bitmap) and its length for a given bytecode.
 *
 * This mirrors the Rust logic:
 * - Scan bytecode
 * - Mark offsets that are real JUMPDEST (0x5b), skipping PUSH data
 * - Store the bitmap as 64-bit words, serialized LE
 *
 * Returns:
 *   artifacts: Uint8Array  // bytes of the bitmap
 *   artifactsLen: number   // length in bytes
 */
export function computeArtifacts(bytecode: Uint8Array): { artifacts: Uint8Array; artifactsLen: number } {
  const JUMPDEST = 0x5b;
  const PUSH1 = 0x60;
  const PUSH32 = 0x7f;

  const codeLen = bytecode.length;

  // Number of 64-bit words needed to cover 'codeLen' bits.
  const BITS_PER_WORD = 64;
  const wordCount = Math.ceil(codeLen / BITS_PER_WORD);

  // Use BigNumber to manipulate 64-bit words.
  // We'll serialize explicitly as little-endian to avoid host endianness ambiguity.
  const words = new Array<BigNumber>(wordCount).fill(BigNumber.from(0));

  // Scan & build bitmap
  let i = 0;
  while (i < codeLen) {
    const op = bytecode[i];

    if (op === JUMPDEST) {
      const wordIdx = Math.floor(i / BITS_PER_WORD);
      const bitIdx = i % BITS_PER_WORD;
      words[wordIdx] = words[wordIdx].or(BigNumber.from(1).shl(bitIdx));
      i += 1;
    } else if (op >= PUSH1 && op <= PUSH32) {
      const pushLen = (op - PUSH1 + 1); // 1..32
      i += 1 + pushLen;
    } else {
      i += 1;
    }
  }

  // Serialize words as little-endian u64s
  const artifacts = new Uint8Array(wordCount * 8);
  const dv = new DataView(artifacts.buffer, artifacts.byteOffset, artifacts.byteLength);
  for (let w = 0; w < wordCount; w++) {
    const lo = words[w].and(BigNumber.from(0xffff_ffff)).toNumber();
    const hi = words[w].shr(32).and(BigNumber.from(0xffff_ffff)).toNumber();
    dv.setUint32(w * 8 + 0, lo, true); // little-endian
    dv.setUint32(w * 8 + 4, hi, true);
  }

  return { artifacts, artifactsLen: artifacts.length };
}

/* ---------------------------
   (Optional) convenience API
   ---------------------------
   If you also want a helper that lays out the "full bytecode" as in your Rust
   (code + padding + artifacts), you can use this:

   The Rust side computes padding to align the (code + padding) so that artifacts
   begin at a machine-word boundary. Since we serialize artifacts in u64 words,
   we’ll align to 8 bytes here as well.
*/

export function bytecodePaddingLen(unpaddedCodeLen: number): number {
  const ALIGN = 8; // match Rust's BYTECODE_ALIGNMENT (u64)
  const rem = unpaddedCodeLen % ALIGN;
  return rem === 0 ? 0 : (ALIGN - rem);
}

export function buildFullBytecode(code: Uint8Array): {
  fullBytecode: Uint8Array;          // code + padding + artifacts
  artifactsOffset: number;           // where artifacts begin
  artifactsLen: number;
  paddingLen: number;
} {
  const { artifacts, artifactsLen } = computeArtifacts(code);
  const paddingLen = bytecodePaddingLen(code.length);
  const full = new Uint8Array(code.length + paddingLen + artifactsLen);

  full.set(code, 0);
  // padding is already zeroed by Uint8Array allocation
  full.set(artifacts, code.length + paddingLen);

  return {
    fullBytecode: full,
    artifactsOffset: code.length + paddingLen,
    artifactsLen,
    paddingLen,
  };
}

/** Compute account-properties hash from a contract bytecode (nonce must be 1). */
function computeAccountPropertiesHashFromBytecode(_bytecodeHex: string): string {
  const bytecode = utils.arrayify(_bytecodeHex); // unpadded "deployed" code
  const BYTECODE_ALIGNMENT = 8; // matches evm_interpreter::BYTECODE_ALIGNMENT in Rust

  // observable_* are computed from UNPADDED code
  const observable_bytecode_hash = utils.arrayify(utils.keccak256(bytecode));
  const observable_bytecode_len = bytecode.length;

  // pad code to BYTECODE_ALIGNMENT; artifacts_len is 0 for our case
  const rem = bytecode.length % BYTECODE_ALIGNMENT;
  const padding = rem === 0 ? 0 : BYTECODE_ALIGNMENT - rem;
  const padded = utils.concat([bytecode, new Uint8Array(padding)]);

  const { artifactsLen, fullBytecode } = buildFullBytecode(bytecode);

  // bytecode_hash is Blake2s over padded code (no artifacts appended here)
  const bytecode_hash = blake2s(fullBytecode);

  // Build AccountProperties fields exactly like Rust's `compute_hash()`:
  // versioning_data (deployed) = (1u64 << 56) in BE
  const versioning_data_be = new Uint8Array([1, 1, 1, 0, 0, 0, 0, 0]);

  // nonce = 1u64 BE
  const nonce_be = u64ToBeBytes(1);

  // balance = 0 as 32-byte BE
  const balance_be = constants.HashZero;

  // lengths as 4-byte BE
  const u32be = (n: number) => {
    const dv = new DataView(new ArrayBuffer(4));
    dv.setUint32(0, n, false);
    return new Uint8Array(dv.buffer);
  };
  const unpadded_code_len_be = u32be(observable_bytecode_len);
  const artifacts_len_be = u32be(artifactsLen);
  const observable_bytecode_len_be = u32be(observable_bytecode_len);
  const preimage = utils.concat([
    versioning_data_be,
    nonce_be,
    balance_be,
    bytecode_hash,
    unpadded_code_len_be,
    artifacts_len_be,
    observable_bytecode_hash,
    observable_bytecode_len_be,
  ]);

  return blake2s(preimage);
}

/** Flat storage key where AccountProperties are stored for a given address. */
function accountPropertiesFlatKey(_address20: string): string {
  // slot key is the 32-byte value with the 20-byte address right-aligned (left-padded with zeros)
  const slotKey = utils.hexZeroPad(_address20, 32) as string;
  return flatStorageKeyForContract(ACCOUNT_PROPERTIES_STORAGE_ADDRESS, slotKey);
}

/** Flatten (address, slot) into canonical flat storage key (B256). */
function flatStorageKeyForContract(_address20: string, _slotKeyB256: string): string {
  // Flat key = blake2s256( pad32(address) || slotKeyB256 )
  const addrPadded32 = utils.hexZeroPad(_address20, 32);
  const slot32 = ensureHex32(_slotKeyB256);
  const preimage = utils.concat([utils.arrayify(addrPadded32), utils.arrayify(slot32)]);
  return blake2s(preimage);
}

function computeGenesisBlockHash(_header: GenesisHeader): string {
  const encInt = (v: BigNumberish | undefined): string => {
    if (v === undefined) return "0x";
    const bn = BigNumber.from(v);
    if (bn.isZero()) return "0x";
    return ethers.utils.hexlify(bn);
  };

  const encBytes = (v: string | undefined): string => (v ?? "0x");

  const fields: any[] = [
    encBytes(_header.parent_hash),
    encBytes(_header.ommers_hash),
    encBytes(_header.beneficiary),
    encBytes(_header.state_root),
    encBytes(_header.transactions_root),
    encBytes(_header.receipts_root),
    encBytes(_header.logs_bloom),
    encInt(_header.difficulty),
    encInt(_header.number),
    encInt(_header.gas_limit),
    encInt(_header.gas_used),
    encInt(_header.timestamp),
    encBytes(_header.extra_data),
    encBytes(_header.mix_hash),
    encBytes(_header.nonce),
  ];

  if (_header.base_fee_per_gas !== undefined) {
    fields.push(encInt(_header.base_fee_per_gas));
  }
  if (_header.withdrawals_root !== undefined) {
    fields.push(encBytes(_header.withdrawals_root));
  }
  if (_header.blob_gas_used !== undefined) {
    fields.push(encInt(_header.blob_gas_used));
  }
  if (_header.excess_blob_gas !== undefined) {
    fields.push(encInt(_header.excess_blob_gas));
  }
  if (_header.parent_beacon_block_root !== undefined) {
    fields.push(encBytes(_header.parent_beacon_block_root));
  }
  if (_header.requests_hash !== undefined) {
    fields.push(encBytes(_header.requests_hash));
  }

  const rlp = utils.RLP.encode(fields);
  console.log(rlp);
  return utils.keccak256(rlp);
}

// ───────────────────────────────────────────────────────────────────────────────
// 3) Hasher implementation (adapts our black boxes to the Merkle module)
// ───────────────────────────────────────────────────────────────────────────────

const Blake2sHasherStub: BlakeLikeHasher = {
  hashLeaf(key32: string, value32: string, nextIndex: number): string {
    const bytes = utils.concat([utils.arrayify(key32), utils.arrayify(value32), u64ToLeBytes(nextIndex)]);
    return blake2s(bytes);
  },
  hashBranch(lhs32: string, rhs32: string): string {
    const bytes = utils.concat([utils.arrayify(lhs32), utils.arrayify(rhs32)]);
    return blake2s(bytes);
  },
};

// ───────────────────────────────────────────────────────────────────────────────
// 4) Genesis header skeleton (values per your snippet)
// ───────────────────────────────────────────────────────────────────────────────

type GenesisHeader = {
  parent_hash: string; // B256
  ommers_hash: string; // B256
  beneficiary: string; // 20 bytes
  state_root: string; // B256
  transactions_root: string; // B256
  receipts_root: string; // B256
  logs_bloom: string; // 256 bytes (EVM bloom)
  difficulty: string; // 32 bytes
  number: string;
  gas_limit: BigNumberish;
  gas_used: BigNumberish;
  timestamp: BigNumberish;
  extra_data: string; // arbitrary bytes
  mix_hash: string; // B256
  nonce: string; // 8 bytes
  base_fee_per_gas: BigNumberish; // present (EIP-1559)
  withdrawals_root?: string;
  blob_gas_used?: BigNumberish;
  excess_blob_gas?: BigNumberish;
  parent_beacon_block_root?: string;
  requests_hash?: string;
};

function buildGenesisHeader(): GenesisHeader {
  return {
    parent_hash: constants.HashZero,
    ommers_hash: EMPTY_OMMER_ROOT_HASH, // EMPTY_OMMER_ROOT_HASH
    beneficiary: constants.AddressZero,
    state_root: constants.HashZero,
    transactions_root: constants.HashZero,
    receipts_root: constants.HashZero,
    logs_bloom: utils.hexZeroPad('0x', 256) as string,
    difficulty: constants.HashZero,
    number: constants.HashZero,
    gas_limit: 5000,
    gas_used: 0,
    timestamp: 0,
    extra_data: "0x",
    mix_hash: constants.HashZero,
    nonce: "0x0000000000000000",
    base_fee_per_gas: 1_000_000_000,
  };
}

// ───────────────────────────────────────────────────────────────────────────────
// 5) Build storage logs from inputs (mirrors your Rust pipeline)
// ───────────────────────────────────────────────────────────────────────────────

type KV = [string, string];

/** Build the complete list of (key,value) pairs for genesis, sorted by key asc. */
async function buildGenesisStorageLogs(initialContractsEntries: [string, string][]): Promise<KV[]> {
  const logs = new Map<string, string>(); // keyHex -> valueHex

  // 1) Accounts from initial contracts
  for (const [addr, bytecode] of initialContractsEntries) {
    const accountHash = computeAccountPropertiesHashFromBytecode(bytecode); // Blake2s(AccountProperties)
    const flatKey = accountPropertiesFlatKey(addr); // B256
    if (logs.has(flatKey)) {
      throw new Error(`Duplicate storage key for account properties: ${flatKey}`);
    }
    logs.set(flatKey, accountHash);
  }

  // 2) RAW additional storage (insert as-is)
  for (const [k, v] of ADDITIONAL_STORAGE_RAW) {
    if (logs.has(k)) {
      throw new Error(`Duplicate storage key in additional_storage_raw: ${k}`);
    }
    logs.set(k, ensureHex32(v));
  }

  // 3) Flatten pretty additional storage
  for (const [address, slots] of Object.entries(ADDITIONAL_STORAGE)) {
    for (const [slotKey, value] of Object.entries(slots)) {
      const flat = flatStorageKeyForContract(address, slotKey);
      if (logs.has(flat)) {
        throw new Error(
          `Duplicate flattened storage key from address=${address}, slot=${slotKey}`
        );
      }
      logs.set(flat, ensureHex32(value));
    }
  }

  // 4) Sort by key asc
  const kv: KV[] = [...logs.entries()]
    .map(([k, v]) => [ensureHex32(k), ensureHex32(v)] as KV)
    .sort(([a], [b]) => (BigInt(a) < BigInt(b) ? -1 : BigInt(a) > BigInt(b) ? 1 : 0));

  return kv;
}

// ───────────────────────────────────────────────────────────────────────────────
// 6) Assemble the state commitment per your formula
// ───────────────────────────────────────────────────────────────────────────────

async function computeGenesisStateCommitment(initialContractsEntries: [string, string][]): Promise<string> {
  const storageLogs = await buildGenesisStorageLogs(initialContractsEntries);

  // Compute Merkle root & leaf count at "genesis"
  const { rootHash, leafCount } = computeGenesisMerkleRoot(storageLogs, Blake2sHasherStub, {
    treeDepth: 64,
  });

  // number = 0, timestamp = 0
  const numberBE = u64ToBeBytes(0);
  const timestampBE = u64ToBeBytes(0);
  const leafCountBE = u64ToBeBytes(leafCount);

  // last_256_block_hashes_blake = Blake2s( [0;32] * 255 || genesis_block.hash() )
  const header = buildGenesisHeader();
  const genesisBlockHash = computeGenesisBlockHash(header); // keccak(header RLP) via ethers (you implement)
  const zeros32 = new Uint8Array(32);
  const chunks: Uint8Array[] = [];
for (let i = 0; i < 255; i++) {
    chunks.push(zeros32);
}
chunks.push(utils.arrayify(ensureHex32(genesisBlockHash)));
const concatenatedChunks = utils.concat(chunks);
const last256 = blake2s(concatenatedChunks);

  // Final state commitment
  const finalBytes = utils.concat([
    utils.arrayify(rootHash),
    leafCountBE,
    numberBE,
    utils.arrayify(last256),
    timestampBE,
  ]);
  const stateCommitment = blake2s(finalBytes);
  return stateCommitment;
}

// ───────────────────────────────────────────────────────────────────────────────
// 7) Build the final genesis.json payload & write it
// ───────────────────────────────────────────────────────────────────────────────

async function buildGenesisJson() {
  // Prepare initial_contracts array: [[address, bytecode], ...]
  // by reading bytecode for each contract name.
  const initialContractsEntries = await Promise.all(
    Object.entries(INITIAL_CONTRACTS).map(async ([address, name]) => {
      const bytecode = await getBytecodeByContractName(name);
      return [address, bytecode] as [string, string];
    })
  );

  const genesisRoot = await computeGenesisStateCommitment(initialContractsEntries);

  return {
    initial_contracts: initialContractsEntries,
    additional_storage: ADDITIONAL_STORAGE,
    additional_storage_raw: ADDITIONAL_STORAGE_RAW,
    execution_version: EXECUTION_VERSION,
    genesis_root: genesisRoot,
  };
}

async function writeGenesis(outPath: string) {
  const payload = await buildGenesisJson();
  const json = JSON.stringify(payload, null, 2);
  await fs.mkdir(path.dirname(outPath), { recursive: true });
  await fs.writeFile(outPath, json + "\n", "utf-8");
  console.log(`✓ Wrote ${outPath}`);
}

// ───────────────────────────────────────────────────────────────────────────────
// 8) CLI
// ───────────────────────────────────────────────────────────────────────────────

const program = new Command();
program
  .name("prepare-genesis")
  .description("Prepare genesis.json (initial contracts, storage, and genesis root).")
  .option("-o, --out <path>", "Output path", "zksync-os-genesis.json")
  .action(async (opts) => {
    const out = path.resolve(process.cwd(), opts.out);
    await writeGenesis(out);
  });

program.parseAsync().catch((err) => {
  console.error(err?.stack ?? String(err));
  process.exit(1);
});

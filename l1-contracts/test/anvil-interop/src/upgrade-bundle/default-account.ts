import { createHash } from "crypto";
import * as fs from "fs";
import {
  CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256,
  CANONICAL_DEFAULT_ACCOUNT_HASH,
  CANONICAL_DEFAULT_ACCOUNT_METADATA_WORD,
  DEFAULT_ACCOUNT_METADATA_WORD_BYTES,
  ERAVM_BYTECODE_WORD_BYTES,
  ERAVM_HASH_LENGTH_OFFSET,
  ERAVM_HASH_RESERVED_OFFSET,
  ERAVM_HASH_VERSION,
  ERAVM_HASH_VERSION_OFFSET,
  MAX_ERAVM_BYTECODE_WORDS,
} from "./constants";
import { readJson, readToml, requireTomlString } from "./common";

interface ContractHashEntry {
  contractName?: string;
  zkBytecodeHash?: string;
}

interface FoundryArtifact {
  bytecode?: { object?: string };
}

function fail(message: string): never {
  throw new Error(`canonical DefaultAccount restore failed: ${message}`);
}

export function zkBytecodeHash(bytecode: Buffer): string {
  if (bytecode.length % ERAVM_BYTECODE_WORD_BYTES !== 0) {
    fail(`bytecode length ${bytecode.length} is not word-aligned`);
  }
  const words = bytecode.length / ERAVM_BYTECODE_WORD_BYTES;
  if (words % 2 !== 1 || words > MAX_ERAVM_BYTECODE_WORDS) {
    fail(`invalid EraVM bytecode word length ${words}`);
  }
  const digest = createHash("sha256").update(bytecode).digest();
  digest[ERAVM_HASH_VERSION_OFFSET] = ERAVM_HASH_VERSION;
  digest[ERAVM_HASH_RESERVED_OFFSET] = 0;
  digest.writeUInt16BE(words, ERAVM_HASH_LENGTH_OFFSET);
  return `0x${digest.toString("hex")}`;
}

export function restoreCanonicalDefaultAccountArtifact(
  artifactPath: string,
  environmentPath: string,
  hashesPath: string
): void {
  const environment = readToml(environmentPath);
  const environmentHash = requireTomlString(environment, "default_aa_hash", environmentPath).toLowerCase();
  if (!/^0x[0-9a-f]{64}$/.test(environmentHash)) fail(`${environmentPath} has an invalid default_aa_hash`);

  const hashes = readJson<ContractHashEntry[]>(hashesPath);
  const reviewed = hashes
    .filter((entry) => entry.contractName === "system-contracts/DefaultAccount")
    .map((entry) => (entry.zkBytecodeHash ?? "").toLowerCase());
  if (reviewed.length !== 1 || reviewed[0] !== environmentHash) {
    fail(`env hash ${environmentHash} does not uniquely match AllContractsHashes.json: ${JSON.stringify(reviewed)}`);
  }

  const artifact = readJson<FoundryArtifact>(artifactPath);
  const raw = artifact.bytecode?.object;
  if (typeof raw !== "string" || !/^(?:0x)?[0-9a-fA-F]+$/.test(raw)) {
    fail(`${artifactPath} has no bytecode.object`);
  }
  const hasHexPrefix = raw.startsWith("0x");
  const bytecode = Buffer.from(hasHexPrefix ? raw.slice(2) : raw, "hex");
  const builtHash = zkBytecodeHash(bytecode);
  if (builtHash === environmentHash) {
    console.log(`DefaultAccount artifact already canonical: ${builtHash}`);
    return;
  }
  if (environmentHash !== CANONICAL_DEFAULT_ACCOUNT_HASH) {
    fail(`no canonical artifact registered for env hash ${environmentHash} (build produced ${builtHash})`);
  }
  if (bytecode.length <= DEFAULT_ACCOUNT_METADATA_WORD_BYTES)
    fail("bytecode is too short to contain the metadata word");

  const executable = bytecode.subarray(0, -DEFAULT_ACCOUNT_METADATA_WORD_BYTES);
  const executableSha256 = createHash("sha256").update(executable).digest("hex");
  if (executableSha256 !== CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256) {
    fail(`executable prefix changed: expected ${CANONICAL_DEFAULT_ACCOUNT_EXECUTABLE_SHA256}, got ${executableSha256}`);
  }
  const canonical = Buffer.concat([executable, Buffer.from(CANONICAL_DEFAULT_ACCOUNT_METADATA_WORD, "hex")]);
  const canonicalHash = zkBytecodeHash(canonical);
  if (canonicalHash !== environmentHash) {
    fail(`restored hash ${canonicalHash} does not match reviewed hash ${environmentHash}`);
  }

  artifact.bytecode = { ...artifact.bytecode, object: `${hasHexPrefix ? "0x" : ""}${canonical.toString("hex")}` };
  const temporaryPath = `${artifactPath}.tmp`;
  fs.writeFileSync(temporaryPath, `${JSON.stringify(artifact)}\n`);
  fs.renameSync(temporaryPath, artifactPath);
  console.log(`Restored canonical DefaultAccount artifact: ${builtHash} -> ${canonicalHash}`);
}

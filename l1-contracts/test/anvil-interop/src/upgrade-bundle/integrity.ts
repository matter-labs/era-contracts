import * as path from "path";
import { ethers } from "ethers";
import { DEPLOY_BUNDLE_SCHEMA, REQUIRED_SUPPORTING_BUNDLE_FILES } from "./constants";
import { fileSha256, readJson, resolveContainedFile } from "./file-system";
import type { BundleManifest, DeployBundleMetadata, SafeBundle } from "./types";

const INTEGRITY_ERROR = "deploy bundle integrity check failed";

function fail(message: string): never {
  throw new Error(`${INTEGRITY_ERROR}: ${message}`);
}

function bundleIdentity(entry: { index: number; file: string; target: string }): string {
  if (
    !Number.isInteger(entry.index) ||
    typeof entry.file !== "string" ||
    path.basename(entry.file) !== entry.file ||
    typeof entry.target !== "string"
  ) {
    fail("invalid bundle identity");
  }
  let target: string;
  try {
    target = ethers.utils.getAddress(entry.target).toLowerCase();
  } catch {
    fail("invalid bundle target address");
  }
  return `${entry.index}\0${entry.file}\0${target}`;
}

export function verifyBundleIntegrity(bundleDirectory: string): DeployBundleMetadata {
  const checkedPath = (relativePath: string): string =>
    resolveContainedFile(bundleDirectory, relativePath, `${INTEGRITY_ERROR}: file escapes bundle directory`);
  const verifyDigest = (relativePath: string, expected: unknown): void => {
    if (typeof expected !== "string" || !/^[0-9a-f]{64}$/.test(expected)) {
      fail(`invalid SHA-256 for ${relativePath}`);
    }
    const actual = fileSha256(checkedPath(relativePath));
    if (actual !== expected) fail(`SHA-256 mismatch for ${relativePath}: expected ${expected}, got ${actual}`);
  };

  const metadata = readJson<DeployBundleMetadata>(checkedPath("bundle-metadata.json"));
  const manifest = readJson<BundleManifest>(checkedPath("prepare/manifest.json"));
  if (metadata.schema !== DEPLOY_BUNDLE_SCHEMA) fail(`unsupported schema: ${String(metadata.schema)}`);
  if (!Array.isArray(metadata.bundles) || metadata.bundles.length === 0) {
    fail("metadata.bundles is empty or not an array");
  }
  if (!Array.isArray(manifest.bundles) || manifest.bundles.length === 0) {
    fail("manifest.bundles is empty or not an array");
  }

  const metadataIdentities = metadata.bundles.map(bundleIdentity);
  const manifestIdentities = manifest.bundles.map(bundleIdentity);
  if (new Set(metadataIdentities).size !== metadataIdentities.length) {
    fail("metadata contains duplicate bundle identities");
  }
  if ([...metadataIdentities].sort().join("\n") !== [...manifestIdentities].sort().join("\n")) {
    fail("metadata bundle list does not match prepare/manifest.json");
  }

  for (const entry of metadata.bundles) {
    const relativePath = path.join("prepare", entry.file);
    verifyDigest(relativePath, entry.sha256);
    const safe = readJson<SafeBundle>(checkedPath(relativePath));
    if (!Array.isArray(safe.transactions)) fail(`${relativePath} has no transactions array`);
    if (safe.transactions.length !== entry.transaction_count) {
      fail(`transaction count mismatch for ${relativePath}`);
    }
  }

  if (!metadata.files || typeof metadata.files !== "object") fail("metadata.files is empty or not an object");
  for (const required of REQUIRED_SUPPORTING_BUNDLE_FILES) {
    if (!(required in metadata.files)) fail(`metadata.files does not include ${required}`);
  }
  for (const [relativePath, digest] of Object.entries(metadata.files)) verifyDigest(relativePath, digest);

  console.log(
    `Deploy bundle integrity: OK (${metadata.bundles.length} bundle(s), ${Object.keys(metadata.files).length} supporting file(s))`
  );
  return metadata;
}

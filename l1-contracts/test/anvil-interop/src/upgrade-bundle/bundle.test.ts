import * as assert from "assert";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { afterEach, describe, it } from "node:test";
import { ethers } from "ethers";
import { packDeployBundle, verifyBundleIntegrity } from "./bundle";
import {
  BUNDLE_METADATA_FILE,
  DEPLOY_BUNDLE_SCHEMA,
  deployBundleMetadataSchema,
  fileSha256,
  loadUpgradeEnvironment,
  readJsonAs,
} from "./common";
import type { DeployBundleMetadata } from "./common";
import { restoreCanonicalDefaultAccountArtifact, zkBytecodeHash } from "./default-account";
import { replayBundleAndVerify } from "./flows";

const temporaryDirectories: string[] = [];
const TEST_DEPLOYER = "0x0000000000000000000000000000000000000002";
const TEST_TRANSACTION_TARGET = "0x0000000000000000000000000000000000000003";
const TEST_BUNDLE_FILES = ["ecosystem.toml", "prepare/01.safe.json", "prepare/manifest.json"];

function temporaryDirectory(): string {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "upgrade-bundle-test-"));
  temporaryDirectories.push(directory);
  return directory;
}

function writeJson(filePath: string, value: unknown): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function writeManifest(directory: string, bundles: unknown[]): void {
  writeJson(path.join(directory, "prepare/manifest.json"), { bundles });
}

/** Metadata whose `files` digests match what is currently on disk. */
function writeMetadata(directory: string, patch: Partial<DeployBundleMetadata> = {}): void {
  const metadata: DeployBundleMetadata = {
    schema: DEPLOY_BUNDLE_SCHEMA,
    upgrade: "v0.31.0-interopB",
    env: "stage",
    contracts_commit: "test",
    contracts_worktree_dirty: false,
    all_contracts_hashes_sha256: "0".repeat(64),
    l1: { chain_id: 1, forked_at_block: 1 },
    deployer_address: TEST_DEPLOYER,
    zk_governance_commit: null,
    toolchain: { forge: "test", rustc: "test", foundry_zksync: null },
    generated_by: null,
    files: Object.fromEntries(TEST_BUNDLE_FILES.map((file) => [file, fileSha256(path.join(directory, file))])),
    ...patch,
  };
  writeJson(path.join(directory, BUNDLE_METADATA_FILE), metadata);
}

function createValidBundle(): string {
  const directory = temporaryDirectory();
  writeJson(path.join(directory, "prepare/01.safe.json"), {
    transactions: [{ to: TEST_TRANSACTION_TARGET, value: "0", data: "0x" }],
  });
  writeManifest(directory, [{ index: 1, file: "01.safe.json", target: TEST_DEPLOYER }]);
  fs.writeFileSync(path.join(directory, "ecosystem.toml"), "old_protocol_version = 1\nnew_protocol_version = 2\n");
  writeMetadata(directory);
  return directory;
}

afterEach(() => {
  while (temporaryDirectories.length > 0) {
    fs.rmSync(temporaryDirectories.pop()!, { recursive: true, force: true });
  }
});

describe("loadUpgradeEnvironment", () => {
  for (const environment of ["stage", "testnet", "mainnet"] as const) {
    it(`parses the real ${environment} TOML configuration`, () => {
      const config = loadUpgradeEnvironment(environment);
      assert.ok(ethers.utils.isAddress(config.bridgehubAddress));
      assert.ok(ethers.utils.isHexString(config.zkAssetId, 32));
    });
  }
});

describe("verifyBundleIntegrity", () => {
  it("accepts a bundle whose files match their recorded digests", () => {
    const metadata = verifyBundleIntegrity(createValidBundle());
    assert.deepStrictEqual(Object.keys(metadata.files).sort(), TEST_BUNDLE_FILES);
  });

  it("rejects modified transaction bytes", () => {
    const directory = createValidBundle();
    fs.appendFileSync(path.join(directory, "prepare/01.safe.json"), " ");
    assert.throws(() => verifyBundleIntegrity(directory), /SHA-256 mismatch for prepare\/01\.safe\.json/);
  });

  it("rejects a manifest edited after packing", () => {
    const directory = createValidBundle();
    writeManifest(directory, [{ index: 2, file: "01.safe.json", target: TEST_DEPLOYER }]);
    assert.throws(() => verifyBundleIntegrity(directory), /SHA-256 mismatch for prepare\/manifest\.json/);
  });

  it("rejects a manifest naming a bundle file the metadata does not cover", () => {
    const directory = createValidBundle();
    writeManifest(directory, [{ index: 1, file: "02.safe.json", target: TEST_DEPLOYER }]);
    writeMetadata(directory);
    assert.throws(
      () => verifyBundleIntegrity(directory),
      /prepare\/02\.safe\.json is in the manifest but not in the metadata/
    );
  });

  it("rejects invalid signer addresses", () => {
    const directory = createValidBundle();
    writeManifest(directory, [{ index: 1, file: "01.safe.json", target: "0xabc" }]);
    writeMetadata(directory);
    assert.throws(() => verifyBundleIntegrity(directory), /bundles\.0\.target: invalid address/);
  });

  it("rejects files outside the bundle", () => {
    const directory = createValidBundle();
    const metadataPath = path.join(directory, BUNDLE_METADATA_FILE);
    const metadata = readJsonAs(metadataPath, deployBundleMetadataSchema);
    metadata.files["../outside.txt"] = "0".repeat(64);
    writeJson(metadataPath, metadata);
    assert.throws(() => verifyBundleIntegrity(directory), /path must stay inside the bundle/);
  });
});

describe("restoreCanonicalDefaultAccountArtifact", () => {
  it("leaves an artifact unchanged when it already has the reviewed hash", () => {
    const directory = temporaryDirectory();
    const bytecode = Buffer.alloc(32, 7);
    const hash = zkBytecodeHash(bytecode);
    const artifactPath = path.join(directory, "DefaultAccount.json");
    const environmentPath = path.join(directory, "environment.toml");
    const hashesPath = path.join(directory, "AllContractsHashes.json");
    writeJson(artifactPath, { bytecode: { object: `0x${bytecode.toString("hex")}` } });
    fs.writeFileSync(environmentPath, `[contracts]\ndefault_aa_hash = "${hash}"\n`);
    writeJson(hashesPath, [{ contractName: "system-contracts/DefaultAccount", zkBytecodeHash: hash }]);
    const before = fs.readFileSync(artifactPath, "utf8");
    restoreCanonicalDefaultAccountArtifact(artifactPath, environmentPath, hashesPath);
    assert.strictEqual(fs.readFileSync(artifactPath, "utf8"), before);
  });

  it("rejects an invalid even-word EraVM bytecode length", () => {
    assert.throws(() => zkBytecodeHash(Buffer.alloc(64)), /invalid EraVM bytecode word length 2/);
  });
});

describe("replayBundleAndVerify", () => {
  it("rejects a private key that does not own the bundle deployer address", async () => {
    await assert.rejects(
      replayBundleAndVerify({
        bundleDirectory: createValidBundle(),
        mode: {
          kind: "broadcast",
          rpcUrl: "http://localhost:8545",
          deployerKey: ethers.Wallet.createRandom().privateKey,
        },
      }),
      /private key does not match the bundle deployer/
    );
  });
});

describe("packDeployBundle", () => {
  it("copies the generation output and records a digest for every file", () => {
    const directory = temporaryDirectory();
    const outputDirectory = path.join(directory, "output");
    const repositoryRoot = path.join(directory, "repository");
    const permanentValuesPath = path.join(directory, "permanent-values.toml");
    const bundleDirectory = path.join(directory, "packed");
    fs.mkdirSync(repositoryRoot, { recursive: true });
    writeJson(path.join(repositoryRoot, "AllContractsHashes.json"), []);
    fs.writeFileSync(permanentValuesPath, "l1_chain_id = 11155111\n");
    fs.mkdirSync(outputDirectory, { recursive: true });
    fs.writeFileSync(path.join(outputDirectory, "ecosystem.toml"), "old_protocol_version = 1\n");
    writeManifest(outputDirectory, [{ index: 1, file: "01.safe.json", target: TEST_DEPLOYER }]);
    writeJson(path.join(outputDirectory, "prepare/01.safe.json"), {
      transactions: [{ to: TEST_TRANSACTION_TARGET, value: "0", data: `0x${"11".repeat(32)}` }],
    });

    packDeployBundle("stage", {
      outputDirectory,
      permanentValuesPath,
      repositoryRoot,
      bundleDirectory,
      provenance: { deployerAddress: TEST_DEPLOYER, forkedAtBlock: 42 },
    });

    const metadata = verifyBundleIntegrity(bundleDirectory);
    assert.deepStrictEqual(Object.keys(metadata.files).sort(), TEST_BUNDLE_FILES);
    assert.deepStrictEqual(metadata.l1, { chain_id: 11155111, forked_at_block: 42 });
    assert.strictEqual(metadata.deployer_address, TEST_DEPLOYER);
    assert.deepStrictEqual(fs.readdirSync(bundleDirectory).sort(), [BUNDLE_METADATA_FILE, "ecosystem.toml", "prepare"]);
  });
});

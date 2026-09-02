import * as assert from "assert";
import * as fs from "fs";
import * as os from "os";
import * as path from "path";
import { afterEach, describe, it } from "node:test";
import { ethers } from "ethers";
import { DEPLOY_BUNDLE_SCHEMA } from "./constants";
import { loadUpgradeEnvironment } from "./environment";
import { fileSha256, readJson } from "./file-system";
import { verifyBundleIntegrity } from "./integrity";
import { restoreCanonicalDefaultAccountArtifact, zkBytecodeHash } from "./default-account";
import { packDeployBundle } from "./pack";
import { replayBundleAndVerify } from "./replay";
import type { DeployBundleMetadata } from "./types";

const temporaryDirectories: string[] = [];
const TEST_BUNDLE_TARGET = "0x0000000000000000000000000000000000000002";
const TEST_TRANSACTION_TARGET = "0x0000000000000000000000000000000000000003";

function temporaryDirectory(): string {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "upgrade-bundle-test-"));
  temporaryDirectories.push(directory);
  return directory;
}

function writeJson(filePath: string, value: unknown): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, `${JSON.stringify(value, null, 2)}\n`);
}

function createValidBundle(): string {
  const directory = temporaryDirectory();
  const safePath = path.join(directory, "prepare/01.safe.json");
  const manifestPath = path.join(directory, "prepare/manifest.json");
  const ecosystemPath = path.join(directory, "ecosystem.toml");
  const manifest = { bundles: [{ index: 1, file: "01.safe.json", target: TEST_BUNDLE_TARGET, steps: [] }] };
  writeJson(safePath, { transactions: [{ to: TEST_TRANSACTION_TARGET, value: "0", data: "0x" }] });
  writeJson(manifestPath, manifest);
  fs.writeFileSync(ecosystemPath, "old_protocol_version = 1\nnew_protocol_version = 2\n");
  const metadata: DeployBundleMetadata = {
    schema: DEPLOY_BUNDLE_SCHEMA,
    upgrade: "v0.31.0-interopB",
    env: "stage",
    protocol_version: { old: ["0x1"], new: ["0x2"] },
    contracts_commit: "test",
    contracts_worktree_dirty: false,
    all_contracts_hashes_sha256: "0".repeat(64),
    l1: { chain_id: 1, forked_at_block: 1 },
    deployer_address: TEST_BUNDLE_TARGET,
    deployer_dependent_deployments: [],
    zk_governance_commit: null,
    toolchain: { forge: "test", rustc: "test", foundry_zksync: null },
    generated_by: null,
    files: {
      "prepare/manifest.json": fileSha256(manifestPath),
      "ecosystem.toml": fileSha256(ecosystemPath),
    },
    bundles: [
      {
        ...manifest.bundles[0],
        transaction_count: 1,
        is_deployer_bundle: true,
        sha256: fileSha256(safePath),
      },
    ],
  };
  writeJson(path.join(directory, "bundle-metadata.json"), metadata);
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
  it("accepts a complete bundle whose manifest and digests match", () => {
    const directory = createValidBundle();
    const metadata = verifyBundleIntegrity(directory);
    assert.strictEqual(metadata.bundles.length, 1);
  });

  it("rejects modified transaction bytes", () => {
    const directory = createValidBundle();
    fs.appendFileSync(path.join(directory, "prepare/01.safe.json"), " ");
    assert.throws(() => verifyBundleIntegrity(directory), /SHA-256 mismatch for prepare\/01\.safe\.json/);
  });

  it("rejects a manifest that executes a different bundle", () => {
    const directory = createValidBundle();
    const manifestPath = path.join(directory, "prepare/manifest.json");
    writeJson(manifestPath, { bundles: [{ index: 2, file: "01.safe.json", target: TEST_BUNDLE_TARGET }] });
    const metadataPath = path.join(directory, "bundle-metadata.json");
    const metadata = JSON.parse(fs.readFileSync(metadataPath, "utf8")) as DeployBundleMetadata;
    metadata.files["prepare/manifest.json"] = fileSha256(manifestPath);
    writeJson(metadataPath, metadata);
    assert.throws(() => verifyBundleIntegrity(directory), /bundle list does not match/);
  });

  it("rejects invalid signer addresses", () => {
    const directory = createValidBundle();
    const metadataPath = path.join(directory, "bundle-metadata.json");
    const metadata = readJson<DeployBundleMetadata>(metadataPath);
    metadata.bundles[0].target = "0xabc";
    writeJson(metadataPath, metadata);
    assert.throws(() => verifyBundleIntegrity(directory), /invalid bundle target address/);
  });

  it("rejects supporting files outside the bundle", () => {
    const directory = createValidBundle();
    const metadataPath = path.join(directory, "bundle-metadata.json");
    const metadata = readJson<DeployBundleMetadata>(metadataPath);
    metadata.files["../outside.txt"] = "0".repeat(64);
    writeJson(metadataPath, metadata);
    assert.throws(() => verifyBundleIntegrity(directory), /file escapes bundle directory: \.\.\/outside\.txt/);
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
        rpcUrl: "http://localhost:8545",
        deployerKey: ethers.Wallet.createRandom().privateKey,
        verifyOnly: false,
      }),
      /private key does not match the bundle deployer/
    );
  });
});

describe("packDeployBundle", () => {
  it("creates a self-consistent bundle and a runnable TypeScript handoff", () => {
    const directory = temporaryDirectory();
    const outputDirectory = path.join(directory, "output");
    const prepareDirectory = path.join(outputDirectory, "prepare");
    const repositoryRoot = path.join(directory, "repository");
    const permanentValuesPath = path.join(directory, "permanent-values.toml");
    const bundleDirectory = path.join(directory, "packed");
    fs.mkdirSync(prepareDirectory, { recursive: true });
    fs.mkdirSync(repositoryRoot, { recursive: true });
    writeJson(path.join(repositoryRoot, "AllContractsHashes.json"), []);
    fs.writeFileSync(
      permanentValuesPath,
      [
        "l1_chain_id = 11155111",
        "[permanent_contracts]",
        "create2_factory_addr = " + JSON.stringify("0x0000000000000000000000000000000000000001"),
        "",
      ].join("\n")
    );
    fs.writeFileSync(
      path.join(outputDirectory, "ecosystem.toml"),
      "old_protocol_version = 1\nnew_protocol_version = 2\n"
    );
    writeJson(path.join(prepareDirectory, "manifest.json"), {
      bundles: [{ index: 1, file: "01.safe.json", target: TEST_BUNDLE_TARGET, steps: ["deploy"] }],
    });
    writeJson(path.join(prepareDirectory, "01.safe.json"), {
      transactions: [
        {
          to: "0x0000000000000000000000000000000000000001",
          value: "0",
          data: `0x${"11".repeat(32)}`,
        },
      ],
    });

    packDeployBundle("stage", { outputDirectory, permanentValuesPath, repositoryRoot, bundleDirectory });

    const metadata = verifyBundleIntegrity(bundleDirectory);
    assert.deepStrictEqual(metadata.protocol_version, { old: ["0x1"], new: ["0x2"] });
    const readme = fs.readFileSync(path.join(bundleDirectory, "README.md"), "utf8");
    assert.match(readme, /yarn --cwd l1-contracts\/test\/anvil-interop bundle replay/);
    assert.match(readme, /CREATE2 deploy/);
  });
});

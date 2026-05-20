#!/usr/bin/env ts-node
/**
 * Run a regen-pipeline command via the published Docker image. Optionally
 * mount a freshly cross-built linux/amd64 `protocol_ops` over the one baked
 * into the image. Foundry (forge/cast/anvil) and the Solidity artifacts stay
 * frozen at the image's build snapshot — only the Rust layer iterates.
 *
 * Why: rebuilding the Docker image on every cargo change costs ~12 min on
 * GitHub Actions. Local cross-compile via `cargo zigbuild` is ~30s
 * incremental. For Rust-only iterations this turns a 50-min loop into a
 * <5-min loop.
 *
 * One-time setup (macOS):
 *   brew install zig
 *   cargo install cargo-zigbuild
 *   rustup target add x86_64-unknown-linux-gnu
 *
 * Required env:
 *   DEPLOYER_PK=<0xhex>          — broadcast signer's private key, OR
 *   DEPLOYER_PK_FILE=<path>      — file holding the same (trimmed)
 *   L1_RPC_URL=<sepolia-rpc>     — Sepolia RPC URL (used for both fork +
 *                                  real-chain broadcast)
 *
 * Optional env:
 *   PROTOCOL_OPS_IMAGE=...       — full image ref. Defaults to
 *                                  ghcr.io/matter-labs/protocol-ops:v31-camp-split
 *   PROTOCOL_OPS_BIN_HOST=...    — explicit path to a pre-built linux/amd64
 *                                  protocol_ops; skips the cross-build step.
 *   USE_BUNDLED_BIN=1            — skip the bind-mount; use the binary baked
 *                                  into the image (Solidity/config-only
 *                                  iteration, no Rust changes).
 *   SKIP_BUILD=1                 — reuse an existing cross-built binary at
 *                                  protocol-ops/target/x86_64-unknown-linux-gnu/release/protocol_ops
 *                                  without re-running cargo zigbuild.
 *
 * Usage:
 *   ts-node scripts/regen-via-docker.ts regen
 *   ts-node scripts/regen-via-docker.ts broadcast
 *   ts-node scripts/regen-via-docker.ts sim-emit <output.json>
 *   ts-node scripts/regen-via-docker.ts shell
 *
 * See `.claude/skills/regenerate-v31-stage-calldata/SKILL.md`
 * (Core principle + Iteration via Docker) for the full pipeline context.
 */
import { spawnSync, type SpawnSyncOptions } from "child_process";
import * as fs from "fs";
import * as path from "path";

import { ethers } from "ethers";

const CONTRACTS_DIR = path.resolve(__dirname, "..");
const ENV_DIR = "upgrade-envs/v0.31.0-interopB";
const OUT_DIR_HOST = path.join(CONTRACTS_DIR, "l1-contracts", ENV_DIR, "output");
const OUT_DIR_CONTAINER = `/contracts/l1-contracts/${ENV_DIR}/output`;
const IMAGE =
  process.env.PROTOCOL_OPS_IMAGE ?? "ghcr.io/matter-labs/protocol-ops:v31-camp-split";

function die(msg: string): never {
  console.error(msg);
  process.exit(1);
}

function readPrivateKey(): string {
  const pk = process.env.DEPLOYER_PK;
  if (pk) return pk;
  const file = process.env.DEPLOYER_PK_FILE;
  if (!file) {
    die("Set DEPLOYER_PK=<0xhex> or DEPLOYER_PK_FILE=<path>");
  }
  if (!fs.existsSync(file)) {
    die(`DEPLOYER_PK_FILE=${file} does not exist`);
  }
  return fs.readFileSync(file, "utf8").trim();
}

/**
 * Cross-build `protocol_ops` for linux/amd64 by running `cargo build` inside
 * the published `protocol-ops-base` image. That image already has the right
 * Rust nightly toolchain pre-installed (see `BUILD_BASE_IMAGE` in
 * `docker/protocol/Dockerfile`), so we don't need zig/cargo-zigbuild on the
 * host. A named Docker volume holds the cargo registry/git cache between
 * runs so subsequent builds are incremental.
 *
 * Output lands at `protocol-ops/target-linux/release/protocol_ops` (separate
 * from the host's macOS `target/`).
 */
const BUILD_BASE_IMAGE = "ghcr.io/matter-labs/protocol-ops-base:latest";
const CARGO_CACHE_VOLUME = "protocol-ops-cargo-cache";
const LINUX_TARGET_DIR_REL = "protocol-ops/target-linux";

function crossBuildViaDocker(): void {
  console.log(`==> Cross-building protocol_ops for linux/amd64 (docker ${BUILD_BASE_IMAGE})…`);
  // Mount the entire `contracts/` tree so protocol_ops's `abigen!` macros
  // can resolve relative paths like `../l1-contracts/zkstack-out/`. The
  // protocol-ops sub-crate's `target/` is overridden with a host
  // `target-linux/` dir so the macOS `target/` stays clean.
  const linuxTargetDir = path.join(CONTRACTS_DIR, LINUX_TARGET_DIR_REL);
  fs.mkdirSync(linuxTargetDir, { recursive: true });

  const args = [
    "run",
    "--rm",
    "--platform",
    "linux/amd64",
    "-v",
    `${CONTRACTS_DIR}:/contracts`,
    "-v",
    `${linuxTargetDir}:/contracts/protocol-ops/target`,
    "-v",
    `${CARGO_CACHE_VOLUME}:/usr/local/cargo`,
    "-w",
    "/contracts/protocol-ops",
    BUILD_BASE_IMAGE,
    "cargo",
    "build",
    "--release",
    "--bin",
    "protocol_ops",
  ];
  const result = spawnSync("docker", args, { stdio: "inherit" });
  if (result.status !== 0) {
    die(`docker cargo build failed (exit ${result.status})`);
  }
}

function resolveBinaryMount(): string[] {
  if (process.env.USE_BUNDLED_BIN) {
    console.log(`==> USE_BUNDLED_BIN=1 — using protocol_ops bundled in ${IMAGE}`);
    return [];
  }
  let binHost = process.env.PROTOCOL_OPS_BIN_HOST;
  if (!binHost) {
    binHost = path.join(CONTRACTS_DIR, LINUX_TARGET_DIR_REL, "release/protocol_ops");
    if (!process.env.SKIP_BUILD) {
      crossBuildViaDocker();
    }
  }
  if (!fs.existsSync(binHost)) {
    die(`ERROR: protocol_ops binary not found at ${binHost}`);
  }
  console.log(`==> Using protocol_ops binary: ${binHost}`);
  return ["-v", `${binHost}:/contracts/protocol-ops/protocol_ops:ro`];
}

/**
 * Bind mounts for files that change per regen. We want the image's Foundry +
 * compiled Solidity artifacts to stay frozen, but configs (CREATE2 salts,
 * legacy_gov_salt, addresses) and the anvil-interop wrappers need to come
 * from the host so a developer's edits take effect without a rebuild.
 */
function commonMounts(): string[] {
  return [
    "-v",
    `${path.join(CONTRACTS_DIR, "l1-contracts", ENV_DIR, "stage.toml")}:/contracts/l1-contracts/${ENV_DIR}/stage.toml:ro`,
    "-v",
    `${path.join(CONTRACTS_DIR, "l1-contracts/upgrade-envs/permanent-values/stage.toml")}:/contracts/l1-contracts/upgrade-envs/permanent-values/stage.toml:ro`,
    "-v",
    `${path.join(CONTRACTS_DIR, "l1-contracts/test/anvil-interop")}:/contracts/l1-contracts/test/anvil-interop:ro`,
    "-v",
    `${OUT_DIR_HOST}:${OUT_DIR_CONTAINER}`,
  ];
}

/**
 * Sourcify is blocked in-container so forge's `ExternalIdentifier`
 * post-success label lookup fails fast (foundry-zksync v0.1.5 silently
 * ignores `--disable-labels` for `forge script`, otherwise the prepare
 * hangs 5–30 min per CTM).
 */
function sourcifyBlock(): string[] {
  return [
    "--add-host",
    "sourcify.dev:127.0.0.1",
    "--add-host",
    "repo.sourcify.dev:127.0.0.1",
  ];
}

function dockerRun(args: string[], opts: SpawnSyncOptions = {}): number {
  const result = spawnSync("docker", args, { stdio: "inherit", ...opts });
  return result.status ?? 1;
}

function cmdRegen(pk: string, rpc: string, binMount: string[]): number {
  // Forward any iteration-skip flags the wrapper script understands. Useful
  // for re-running just PUVT (`SKIP_PREPARE=1 SKIP_BROADCAST=1`) after
  // refreshing only the protocol_ops binary, or skipping PUVT for fast
  // iteration on the sim layer.
  const passthrough: string[] = [];
  for (const k of ["SKIP_PREPARE", "SKIP_BROADCAST", "SKIP_PUVT", "KEEP_ANVIL"]) {
    if (process.env[k]) {
      passthrough.push("-e", `${k}=${process.env[k]}`);
    }
  }
  const args = [
    "run",
    "--rm",
    "--platform",
    "linux/amd64",
    ...sourcifyBlock(),
    "-e",
    `DEPLOYER_PK=${pk}`,
    "-e",
    `L1_RPC_URL=${rpc}`,
    "-e",
    `L1_FORK_URL=${rpc}`,
    ...passthrough,
    ...binMount,
    ...commonMounts(),
    "-w",
    "/contracts/l1-contracts",
    IMAGE,
    "bash",
    "test/anvil-interop/regen-and-verify-stage.sh",
  ];
  return dockerRun(args);
}

/**
 * Phase 2 broadcaster. The work splits into two halves:
 *
 *   1. **Filter** — read every prepare bundle signed by our EOA, merge them,
 *      drop `approve` + GW-priority calls (we can't fund them on Sepolia),
 *      drop CREATE2 deploys whose target already has code on chain. Pure
 *      host-side work, no Docker needed.
 *   2. **Broadcast** — invoke `protocol_ops dev execute-safe` on the
 *      filtered bundle via Docker so the linux `protocol_ops` binary + linux
 *      Foundry inside the image run the signed txs reproducibly.
 *
 * Keep `FUNDED_SELECTORS` in sync with `protocol-ops/src/commands/ecosystem/simulator.rs`.
 */
const CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";
const FUNDED_SELECTORS = [
  "0x095ea7b3", // approve(address,uint256)
  "0xd52471c1", // requestL2TransactionDirect(...)
  "0x24fd57fb", // requestL2TransactionTwoBridges(...)
];

interface SafeTx {
  to: string;
  value?: string;
  data: string;
}
interface SafeBundle {
  transactions: SafeTx[];
  [k: string]: unknown;
}

function isFundedCall(dataHex: string): boolean {
  const d = dataHex.toLowerCase();
  return FUNDED_SELECTORS.some((s) => d.startsWith(s));
}

/**
 * CREATE2 address = `keccak256(0xff || factory || salt || keccak256(initcode))[12:]`.
 * Data layout in CREATE2-factory calls: `salt(32) || initcode`.
 */
function computeCreate2Address(txData: string): string | null {
  const stripped = txData.startsWith("0x") ? txData.slice(2) : txData;
  if (stripped.length < 64) return null;
  const salt = "0x" + stripped.slice(0, 64);
  const initcode = "0x" + stripped.slice(64);
  try {
    return ethers.utils.getCreate2Address(
      CREATE2_FACTORY,
      salt,
      ethers.utils.keccak256(initcode)
    );
  } catch {
    return null;
  }
}

async function cmdBroadcast(pk: string, rpc: string, binMount: string[]): Promise<number> {
  const wallet = new ethers.Wallet(pk);
  console.log(`Deployer EOA: ${wallet.address}`);

  const prepareDir = path.join(OUT_DIR_HOST, "stage/prepare");
  const stageOutDir = path.join(OUT_DIR_HOST, "stage");
  if (!fs.existsSync(prepareDir)) {
    die(`${prepareDir} does not exist — run regen first`);
  }

  const deployerLc = wallet.address.toLowerCase();
  const sourceBundles = fs
    .readdirSync(prepareDir)
    .filter((f) => f.endsWith(`${deployerLc}.safe.json`))
    .sort()
    .map((f) => path.join(prepareDir, f));
  if (sourceBundles.length === 0) {
    die(
      `No deployer bundle for ${wallet.address} under ${prepareDir} — run regen first`
    );
  }
  console.log(`Source deployer bundles (${sourceBundles.length}):`);
  for (const b of sourceBundles) console.log(`  ${b}`);

  // 1) Merge bundles, drop funded calls.
  let merged: SafeBundle | null = null;
  const toConsider: SafeTx[] = [];
  let totalIn = 0;
  let fundedDropped = 0;
  for (const src of sourceBundles) {
    const parsed = JSON.parse(fs.readFileSync(src, "utf8")) as SafeBundle;
    if (merged === null) {
      const { transactions: _ignored, ...rest } = parsed;
      merged = { ...rest, transactions: [] };
    }
    const txs = parsed.transactions ?? [];
    totalIn += txs.length;
    for (const tx of txs) {
      if (isFundedCall(tx.data ?? "0x")) fundedDropped += 1;
      else toConsider.push(tx);
    }
  }
  if (merged === null) die("Internal: no bundles loaded");

  // 2) Skip CREATE2 deploys already on chain; pass everything else through.
  const provider = new ethers.providers.JsonRpcProvider(rpc);
  const factoryLc = CREATE2_FACTORY.toLowerCase();
  const toSend: SafeTx[] = [];
  let create2Total = 0;
  const create2Skipped: string[] = [];
  let nonCreate2Kept = 0;
  for (const tx of toConsider) {
    if (tx.to.toLowerCase() === factoryLc) {
      create2Total += 1;
      const addr = computeCreate2Address(tx.data);
      if (addr === null) {
        toSend.push(tx);
        continue;
      }
      const code = await provider.getCode(addr);
      if (code && code !== "0x") {
        create2Skipped.push(addr);
      } else {
        toSend.push(tx);
      }
    } else {
      nonCreate2Kept += 1;
      toSend.push(tx);
    }
  }

  merged.transactions = toSend;
  const filteredPath = path.join(stageOutDir, "deployer-bundle-filtered.safe.json");
  fs.writeFileSync(filteredPath, JSON.stringify(merged, null, 2));
  console.log(
    `Merged: ${totalIn} txs across ${sourceBundles.length} bundle(s) → ` +
      `${fundedDropped} funded dropped, ` +
      `${create2Total} CREATE2 → ${create2Total - create2Skipped.length} new ` +
      `(${create2Skipped.length} already deployed), ` +
      `${nonCreate2Kept} other → keep all`
  );

  if (toSend.length === 0) {
    console.log(
      `Nothing new to broadcast against ${rpc} — every kept tx is already on chain.`
    );
    return 0;
  }

  // 3) Execute the filtered bundle via Docker so `protocol_ops dev execute-safe`
  //    + foundry use the linux binaries inside the image (reproducible).
  const filteredContainer = `${OUT_DIR_CONTAINER}/stage/deployer-bundle-filtered.safe.json`;
  const executedContainer = `${OUT_DIR_CONTAINER}/stage/sepolia-deployer-deploys.json`;
  console.log(`Executing ${filteredPath} against ${rpc} …`);
  const args = [
    "run",
    "--rm",
    "--platform",
    "linux/amd64",
    "-e",
    `DEPLOYER_PK=${pk}`,
    "-e",
    `L1_RPC_URL=${rpc}`,
    ...binMount,
    ...commonMounts(),
    "-w",
    "/contracts/l1-contracts",
    IMAGE,
    "protocol_ops",
    "dev",
    "execute-safe",
    "--safe-file",
    filteredContainer,
    "--l1-rpc-url",
    rpc,
    "--private-key",
    pk,
    "--out",
    executedContainer,
  ];
  return dockerRun(args);
}

function cmdSimEmit(pk: string, binMount: string[], outJson: string): number {
  const outParentHost = path.resolve(path.dirname(outJson));
  const outFile = path.basename(outJson);
  if (!fs.existsSync(outParentHost)) {
    die(`Output parent directory does not exist: ${outParentHost}`);
  }
  const campASigner = new ethers.Wallet(pk).address;
  const args = [
    "run",
    "--rm",
    "--platform",
    "linux/amd64",
    ...binMount,
    "-v",
    `${path.join(CONTRACTS_DIR, "l1-contracts", ENV_DIR, "stage.toml")}:/contracts/l1-contracts/${ENV_DIR}/stage.toml:ro`,
    "-v",
    `${path.join(CONTRACTS_DIR, "l1-contracts/upgrade-envs/permanent-values/stage.toml")}:/contracts/l1-contracts/upgrade-envs/permanent-values/stage.toml:ro`,
    "-v",
    `${OUT_DIR_HOST}:${OUT_DIR_CONTAINER}`,
    "-v",
    `${outParentHost}:/sim-out`,
    "-w",
    "/contracts",
    IMAGE,
    "protocol_ops",
    "ecosystem",
    "governance-toml-to-simulator",
    "--env",
    "stage",
    "--governance-toml",
    `/contracts/l1-contracts/${ENV_DIR}/output/stage/ecosystem.toml`,
    "--include-manifest",
    `/contracts/l1-contracts/${ENV_DIR}/output/stage/prepare/manifest.json`,
    "--camp-a-signers",
    campASigner,
    "--out",
    `/sim-out/${outFile}`,
  ];
  return dockerRun(args);
}

function cmdShell(binMount: string[]): number {
  const args = [
    "run",
    "--rm",
    "-it",
    "--platform",
    "linux/amd64",
    ...sourcifyBlock(),
    ...binMount,
    ...commonMounts(),
    "-w",
    "/contracts/l1-contracts",
    IMAGE,
    "bash",
  ];
  return dockerRun(args);
}

function usage(): never {
  console.error(`Usage:
  ts-node scripts/regen-via-docker.ts regen
  ts-node scripts/regen-via-docker.ts broadcast
  ts-node scripts/regen-via-docker.ts sim-emit <output.json>
  ts-node scripts/regen-via-docker.ts shell`);
  process.exit(1);
}

async function main(): Promise<void> {
  const sub = process.argv[2];
  if (!sub) usage();

  const needsPk = ["regen", "broadcast", "sim-emit"].includes(sub);
  const needsRpc = ["regen", "broadcast"].includes(sub);

  const pk = needsPk ? readPrivateKey() : "";
  const rpc = needsRpc ? process.env.L1_RPC_URL ?? "" : "";
  if (needsRpc && !rpc) die("L1_RPC_URL is required");

  const binMount = resolveBinaryMount();

  let status: number;
  switch (sub) {
    case "regen":
      status = cmdRegen(pk, rpc, binMount);
      break;
    case "broadcast":
      status = await cmdBroadcast(pk, rpc, binMount);
      break;
    case "sim-emit": {
      const outJson = process.argv[3];
      if (!outJson) {
        die("Usage: regen-via-docker.ts sim-emit <output.json>");
      }
      status = cmdSimEmit(pk, binMount, outJson);
      break;
    }
    case "shell":
      status = cmdShell(binMount);
      break;
    default:
      usage();
  }

  process.exit(status);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

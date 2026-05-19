#!/usr/bin/env ts-node
/**
 * Phase 2 of the v31-stage regen pipeline. Broadcasts every Camp-A bundle
 * (= signed by the EOA whose private key we hold) from `upgrade-prepare-all`
 * to real Sepolia, with two filters applied:
 *
 *   - **Funded calls dropped.** `approve(...)` + `requestL2TransactionDirect(...)`
 *     need ZK base-token balance the deployer EOA doesn't hold on Sepolia.
 *     The tx-simulator's L1-side checks don't need the GW-side L2 state.
 *
 *   - **Already-deployed CREATE2 dropped.** Idempotent re-runs: re-broadcasting
 *     after a partial broadcast or after a prior upgrade ceremony only sends
 *     the deploys that are net-new for this regen.
 *
 * Required env:
 *   DEPLOYER_PK=<0xhex>        — broadcast signer's private key, OR
 *   DEPLOYER_PK_FILE=<path>    — file holding the same (trimmed)
 *   L1_RPC_URL=<real-sepolia>  — Sepolia RPC URL
 *
 * Usage (from `l1-contracts/test/anvil-interop/`):
 *   DEPLOYER_PK_FILE=~/.test_pk \
 *   L1_RPC_URL=https://eth-sepolia.g.alchemy.com/v2/<key> \
 *   yarn ts-node broadcast-deployer-bundle-to-sepolia.ts
 *
 * See `contracts/.claude/skills/regenerate-v31-stage-calldata/SKILL.md`
 * ("Core principle": Camp A / Camp B) for the full pipeline context.
 */
import { spawnSync } from "child_process";
import * as fs from "fs";
import * as path from "path";

import { ethers } from "ethers";

const CREATE2_FACTORY = "0x4e59b44847b379578588920cA78FbF26c0B4956C";

// Keep in sync with protocol-ops's `FUNDED_SELECTORS` in
// `commands/ecosystem/simulator.rs`.
const FUNDED_SELECTORS = [
  "0x095ea7b3", // approve(address,uint256)
  "0xd52471c1", // requestL2TransactionDirect(...)
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

function resolveProtocolOpsBinary(contractsRoot: string): string {
  const candidates = [
    path.join(contractsRoot, "protocol-ops/target/debug/protocol_ops"),
    path.join(contractsRoot, "protocol-ops/target/release/protocol_ops"),
    path.join(contractsRoot, "protocol-ops/protocol_ops"),
  ];
  for (const c of candidates) {
    if (fs.existsSync(c) && (fs.statSync(c).mode & 0o111) !== 0) return c;
  }
  const which = spawnSync("which", ["protocol_ops"], { encoding: "utf8" });
  if (which.status === 0 && which.stdout.trim()) {
    return which.stdout.trim();
  }
  die("protocol_ops binary not found — build it with 'cd protocol-ops && cargo build'");
}

function isFundedCall(dataHex: string): boolean {
  const lower = dataHex.toLowerCase();
  return FUNDED_SELECTORS.some((s) => lower.startsWith(s));
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
    return ethers.utils.getCreate2Address(CREATE2_FACTORY, salt, ethers.utils.keccak256(initcode));
  } catch {
    return null;
  }
}

async function main(): Promise<void> {
  const rpcUrl = process.env.L1_RPC_URL;
  if (!rpcUrl) die("L1_RPC_URL is required (point at real Sepolia)");

  const pk = readPrivateKey();
  const wallet = new ethers.Wallet(pk);
  console.log(`Deployer EOA: ${wallet.address}`);

  const scriptDir = __dirname;
  const l1ContractsDir = path.resolve(scriptDir, "..", "..");
  const contractsRoot = path.resolve(l1ContractsDir, "..");
  const protocolOps = resolveProtocolOpsBinary(contractsRoot);

  const outDir = path.join(l1ContractsDir, "upgrade-envs/v0.31.0-interopB/output/stage");
  const prepareDir = path.join(outDir, "prepare");
  if (!fs.existsSync(prepareDir)) {
    die(`${prepareDir} does not exist — run regen-and-verify-stage.sh first`);
  }

  const deployerLc = wallet.address.toLowerCase();
  const sourceBundles = fs
    .readdirSync(prepareDir)
    .filter((f) => f.endsWith(`${deployerLc}.safe.json`))
    .sort()
    .map((f) => path.join(prepareDir, f));
  if (sourceBundles.length === 0) {
    die(`No deployer bundle for ${wallet.address} under ${prepareDir} — run regen-and-verify-stage.sh first`);
  }
  console.log(`Source deployer bundles (${sourceBundles.length}):`);
  for (const b of sourceBundles) console.log(`  ${b}`);

  // 1) Merge bundles, drop funded calls (camp-A signer can't fund them on
  //    real Sepolia). Everything else is fair game for broadcast.
  let merged: SafeBundle | null = null;
  const toConsider: SafeTx[] = [];
  let inputTxCount = 0;
  let fundedDropped = 0;
  for (const src of sourceBundles) {
    const parsed = JSON.parse(fs.readFileSync(src, "utf8")) as SafeBundle;
    if (merged === null) {
      const rest: Record<string, unknown> = { ...parsed };
      delete rest.transactions;
      merged = { ...rest, transactions: [] };
    }
    const txs = parsed.transactions ?? [];
    inputTxCount += txs.length;
    for (const tx of txs) {
      if (isFundedCall(tx.data ?? "0x")) fundedDropped += 1;
      else toConsider.push(tx);
    }
  }
  if (merged === null) die("Internal: no bundles loaded");

  // 2) For CREATE2-factory calls, skip those whose computed deploy address
  //    already has bytecode on chain (idempotent re-runs). Non-CREATE2 calls
  //    (legacy-Gov ceremonies, transferOwnership, setNewVersionUpgrade, …)
  //    pass through; execute-safe surfaces any on-chain reverts loudly
  //    (rotate `legacy_gov_salt` in stage.toml to escape stale op ids).
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
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
        // Unparsable — keep, let the broadcaster fail loudly
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
  const filteredPath = path.join(outDir, "deployer-bundle-filtered.safe.json");
  fs.writeFileSync(filteredPath, JSON.stringify(merged, null, 2));
  console.log(
    `Merged: ${inputTxCount} txs across ${sourceBundles.length} bundle(s) → ` +
      `${fundedDropped} funded dropped, ` +
      `${create2Total} CREATE2 → ${create2Total - create2Skipped.length} new ` +
      `(${create2Skipped.length} already deployed), ` +
      `${nonCreate2Kept} other → keep all`
  );

  if (toSend.length === 0) {
    console.log(`Nothing new to broadcast against ${rpcUrl} — every kept tx is already on chain.`);
    return;
  }

  const executedOut = path.join(outDir, "sepolia-deployer-deploys.json");
  console.log(`Executing ${filteredPath} against ${rpcUrl} …`);
  const result = spawnSync(
    protocolOps,
    [
      "dev",
      "execute-safe",
      "--safe-file",
      filteredPath,
      "--l1-rpc-url",
      rpcUrl,
      "--private-key",
      pk,
      "--out",
      executedOut,
    ],
    { stdio: "inherit" }
  );
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
  console.log(`=== Done ===\nExecuted log: ${executedOut}`);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});

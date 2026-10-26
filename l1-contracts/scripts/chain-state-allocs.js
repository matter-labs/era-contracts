#!/usr/bin/env node
/* eslint-env node */
/* eslint-disable @typescript-eslint/no-var-requires */

// Converts one anvil-interop chain-state dump (`test/anvil-interop/chain-states/<version>/<chainId>.json.gz`)
// into the allocs file `vm.loadAllocs` reads, so a Foundry test can start from a frozen release's state.
//
//   node scripts/chain-state-allocs.js <stateVersion> <chainId>
//
// Writes `test/anvil-interop/outputs/allocs/<stateVersion>-<chainId>.json` (git-ignored) and prints
// `abi.encode(uint256 blockNumber, uint256 blockTimestamp)` of the dumped block as hex on stdout.

const fs = require("fs");
const path = require("path");
const zlib = require("zlib");

const STATE_VERSION_PATTERN = /^v\d+\.\d+\.\d+$/;
const CHAIN_ID_PATTERN = /^\d+$/;

function toHexQuantity(value) {
  return `0x${BigInt(value).toString(16)}`;
}

function encodeUint256(value) {
  return BigInt(value).toString(16).padStart(64, "0");
}

function main() {
  const [stateVersion, chainId] = process.argv.slice(2);
  if (!STATE_VERSION_PATTERN.test(stateVersion ?? "") || !CHAIN_ID_PATTERN.test(chainId ?? "")) {
    throw new Error("usage: chain-state-allocs.js <v<major>.<minor>.<patch>> <chainId>");
  }
  const anvilInteropDir = path.join(__dirname, "../test/anvil-interop");
  const dumpPath = path.join(anvilInteropDir, "chain-states", stateVersion, `${chainId}.json.gz`);
  const dump = JSON.parse(zlib.gunzipSync(fs.readFileSync(dumpPath)).toString("utf-8"));

  const allocs = {};
  for (const [address, account] of Object.entries(dump.accounts)) {
    allocs[address] = {
      nonce: toHexQuantity(account.nonce),
      balance: toHexQuantity(account.balance),
      code: account.code,
      storage: account.storage,
    };
  }

  const outDir = path.join(anvilInteropDir, "outputs", "allocs");
  fs.mkdirSync(outDir, { recursive: true });
  fs.writeFileSync(path.join(outDir, `${stateVersion}-${chainId}.json`), JSON.stringify(allocs));

  process.stdout.write(`0x${encodeUint256(dump.block.number)}${encodeUint256(dump.block.timestamp)}`);
}

main();

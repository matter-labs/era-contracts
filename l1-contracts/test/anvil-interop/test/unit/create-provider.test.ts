/**
 * Unit tests for the provider polling interval.
 *
 * The interval is load-bearing in both directions: 100ms against Anvil is what took the interop
 * suite from 238s to 102s, and 100ms against a real `LIVE_*_RPC` endpoint would be ten requests
 * per second per waiter — the relay and finalization loops in temp-sdk.ts sleep
 * `provider.pollingInterval` per iteration and do not handle rate limiting, so one 429 aborts a
 * live run. These tests pin which URLs get which default.
 *
 * Run with: yarn test:create-provider
 */

import * as assert from "assert/strict";
import { createSuite } from "./harness";
import {
  LOCAL_POLLING_INTERVAL_MS,
  REMOTE_POLLING_INTERVAL_MS,
  createProvider,
  isLocalRpcUrl,
  pollingIntervalFor,
} from "../../src/core/utils";

const { test, run } = createSuite("create-provider");

test("recognises the local RPCs the harness actually starts", () => {
  // The anvil-interop chains: L1 on 9545, L2s on 4050-4054, plus port offsets for parallel shards.
  for (const url of [
    "http://127.0.0.1:9545",
    "http://localhost:4050",
    "http://127.0.0.1:4154",
    "http://0.0.0.0:8545",
    "http://[::1]:9545",
    "http://app.localhost:3050",
  ]) {
    assert.equal(isLocalRpcUrl(url), true, url);
    assert.equal(pollingIntervalFor(url), LOCAL_POLLING_INTERVAL_MS, url);
  }
});

// The finding that motivated this: live mode feeds LIVE_*_RPC through the same helper via
// setupLiveState() and getGatewayProvider().
test("treats live and remote RPCs as remote, keeping ethers' conservative default", () => {
  for (const url of [
    "https://mainnet.era.zksync.io",
    "https://sepolia.infura.io/v3/deadbeef",
    "http://45.130.104.125:3050",
    "wss://gateway.example.org/ws",
    "https://localhost.example.com/rpc", // not a local host despite the prefix
  ]) {
    assert.equal(isLocalRpcUrl(url), false, url);
    assert.equal(pollingIntervalFor(url), REMOTE_POLLING_INTERVAL_MS, url);
  }
});

test("keeps the remote default at ethers' own, so live behaviour is unchanged", () => {
  // Live mode ran at ethers' 4000ms default before this helper existed; it must still.
  assert.equal(REMOTE_POLLING_INTERVAL_MS, 4000);
  assert.ok(LOCAL_POLLING_INTERVAL_MS < REMOTE_POLLING_INTERVAL_MS);
});

// ethers' setter rejects anything where `parseInt(String(value)) != value`, so the constants have to
// be whole numbers or every provider construction throws "invalid polling interval" on assignment.
test("the interval it picks is one ethers will accept", () => {
  const provider = createProvider("http://127.0.0.1:9545");
  assert.equal(provider.pollingInterval, LOCAL_POLLING_INTERVAL_MS);
});

test("treats a URL it cannot parse as remote", () => {
  assert.equal(isLocalRpcUrl("not a url"), false);
  assert.equal(pollingIntervalFor("not a url"), REMOTE_POLLING_INTERVAL_MS);
});

run();

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
import * as fs from "fs";
import * as path from "path";
import {
  LOCAL_POLLING_INTERVAL_MS,
  REMOTE_POLLING_INTERVAL_MS,
  createProvider,
  isLocalRpcUrl,
  pollingIntervalFor,
} from "../../src/core/utils";

const tests: Array<[string, () => void]> = [];
function test(name: string, fn: () => void): void {
  tests.push([name, fn]);
}

/** Runs fn with ANVIL_INTEROP_POLLING_INTERVAL_MS set (or cleared), then restores it. */
function withOverride(value: string | undefined, fn: () => void): void {
  const key = "ANVIL_INTEROP_POLLING_INTERVAL_MS";
  const previous = process.env[key];
  if (value === undefined) delete process.env[key];
  else process.env[key] = value;
  try {
    fn();
  } finally {
    if (previous === undefined) delete process.env[key];
    else process.env[key] = previous;
  }
}

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
    withOverride(undefined, () => assert.equal(pollingIntervalFor(url), LOCAL_POLLING_INTERVAL_MS, url));
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
    withOverride(undefined, () => assert.equal(pollingIntervalFor(url), REMOTE_POLLING_INTERVAL_MS, url));
  }
});

test("keeps the remote default at ethers' own, so live behaviour is unchanged", () => {
  // Live mode ran at ethers' 4000ms default before this helper existed; it must still.
  assert.equal(REMOTE_POLLING_INTERVAL_MS, 4000);
  assert.ok(LOCAL_POLLING_INTERVAL_MS < REMOTE_POLLING_INTERVAL_MS);
});

test("honours the env override for both local and remote", () => {
  withOverride("250", () => {
    assert.equal(pollingIntervalFor("http://127.0.0.1:9545"), 250);
    assert.equal(pollingIntervalFor("https://mainnet.era.zksync.io"), 250);
  });
});

test("ignores an empty override rather than reading it as zero", () => {
  withOverride("", () => {
    assert.equal(pollingIntervalFor("http://127.0.0.1:9545"), LOCAL_POLLING_INTERVAL_MS);
  });
});

// A silently-zero or NaN interval would spin the wait loops as fast as the event loop allows,
// which against a live endpoint is exactly the failure this is meant to avoid.
test("rejects a nonsensical override instead of degrading quietly", () => {
  for (const bad of ["abc", "0", "-100"]) {
    withOverride(bad, () => {
      assert.throws(() => pollingIntervalFor("http://127.0.0.1:9545"), /positive whole number/, bad);
    });
  }
});

// ethers' setter rejects anything where parseInt(String(value)) != value, so these would pass a
// looser check here and then throw "invalid polling interval" from inside createProvider — a
// worse error, further from the cause.
test("rejects overrides ethers itself would reject", () => {
  for (const bad of ["0.1", "1.5", "Infinity", "1e-3"]) {
    withOverride(bad, () => {
      assert.throws(() => pollingIntervalFor("http://127.0.0.1:9545"), /positive whole number/, bad);
      assert.throws(() => createProvider("http://127.0.0.1:9545"), /positive whole number/, bad);
    });
  }
});

test("accepts an integer override, and ethers accepts it too", () => {
  withOverride("250", () => {
    const provider = createProvider("http://127.0.0.1:9545");
    assert.equal(provider.pollingInterval, 250);
  });
});

test("treats a URL it cannot parse as remote", () => {
  assert.equal(isLocalRpcUrl("not a url"), false);
  withOverride(undefined, () => assert.equal(pollingIntervalFor("not a url"), REMOTE_POLLING_INTERVAL_MS));
});

// The point of the helper is that it is the *only* provider constructor: the first conversion pass
// missed the `new ethers.providers.*` spelling, which silently left 07/13/08 and the upgrade runner
// on 4s polling, and a later pass still missed run-fork-upgrade-test.ts. Assert the invariant
// instead of trusting it.
test("no provider is constructed outside createProvider", () => {
  const root = path.resolve(__dirname, "../..");
  const offenders: string[] = [];

  const walk = (dir: string): void => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      if (entry.name === "node_modules" || entry.name === "outputs" || entry.name.startsWith(".")) continue;
      const full = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(full);
        continue;
      }
      if (!entry.name.endsWith(".ts")) continue;
      if (full === path.join(root, "src/core/utils.ts")) continue; // the one permitted constructor
      const text = fs.readFileSync(full, "utf8");
      if (/new\s+(ethers\.)?providers\.JsonRpcProvider\s*\(/.test(text)) {
        offenders.push(path.relative(root, full));
      }
    }
  };

  walk(root);
  assert.deepEqual(offenders, [], `construct these through createProvider(): ${offenders.join(", ")}`);
});

let failed = 0;
for (const [name, fn] of tests) {
  try {
    fn();
    console.log(`  ✓ ${name}`);
  } catch (error) {
    failed++;
    console.error(`  ✗ ${name}`);
    console.error(`    ${(error as Error).message}`);
  }
}

console.log(`\n${tests.length - failed}/${tests.length} create-provider tests passed`);
if (failed > 0) {
  process.exit(1);
}

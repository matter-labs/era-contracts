#!/usr/bin/env node

import { AbiCoder, providers } from "ethers";
import { INTEROP_BUNDLE_SENT_TOPIC, INTEROP_BUNDLE_TUPLE_TYPE, INTEROP_CENTER_ADDR } from "./src/const";

const abiCoder = AbiCoder.defaultAbiCoder();

function usage() {
  console.log("Usage:");
  console.log("  ts-node decode-interop-event.ts --data <eventDataHex>");
  console.log("  ts-node decode-interop-event.ts --tx <txHash> --rpc <rpcUrl> [--address <interopCenterAddress>]");
}

function getArg(flag: string): string | undefined {
  const idx = process.argv.indexOf(flag);
  return idx >= 0 ? process.argv[idx + 1] : undefined;
}

async function getEventDataFromTx(txHash: string, rpcUrl: string, address: string): Promise<string> {
  const provider = new providers.JsonRpcProvider(rpcUrl);
  const receipt = await provider.getTransactionReceipt(txHash);
  if (!receipt) {
    throw new Error(`Transaction receipt not found: ${txHash}`);
  }

  const found = receipt.logs.find(
    (log) => log.address.toLowerCase() === address.toLowerCase() && log.topics[0] === INTEROP_BUNDLE_SENT_TOPIC
  );

  if (!found) {
    throw new Error(`InteropBundleSent log not found in tx ${txHash}`);
  }

  return found.data;
}

function decodeEventData(eventData: string): void {
  const decoded = abiCoder.decode(["bytes32", "bytes32", INTEROP_BUNDLE_TUPLE_TYPE], eventData);

  console.log("\n=== InteropBundleSent Event Decoded ===\n");
  console.log("l2l1MsgHash:", decoded[0]);
  console.log("interopBundleHash:", decoded[1]);

  const bundle = decoded[2];
  console.log("\nInteropBundle:");
  console.log("  version:", bundle[0]);
  console.log("  nonce:", bundle[1].toString());
  console.log("  destinationChainId:", bundle[2].toString());
  console.log("  canonicalHash:", bundle[3]);

  const calls = bundle[4];
  console.log(`\n  calls (${calls.length}):`);

  for (let i = 0; i < calls.length; i++) {
    const call = calls[i];
    console.log(`\n  Call ${i}:`);
    console.log(`    version: ${call[0]}`);
    console.log(`    indirectCall: ${call[1]}`);
    console.log(`    address1 (index 2): ${call[2]}`);
    console.log(`    address2 (index 3): ${call[3]}`);
    console.log(`    value: ${call[4].toString()}`);
    console.log(`    data length: ${call[5].length} bytes`);
    console.log(`    data (first 100 chars): ${call[5].slice(0, 100)}`);
  }
}

async function main() {
  const dataArg = getArg("--data");
  const txHash = getArg("--tx");
  const rpcUrl = getArg("--rpc");
  const address = getArg("--address") || INTEROP_CENTER_ADDR;

  if (!dataArg && !(txHash && rpcUrl)) {
    usage();
    process.exit(1);
  }

  const eventData = dataArg ?? (await getEventDataFromTx(txHash!, rpcUrl!, address));
  decodeEventData(eventData);
}

main().catch((error) => {
  console.error("Failed to decode:", error);
  process.exit(1);
});

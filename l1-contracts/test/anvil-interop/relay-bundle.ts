#!/usr/bin/env node

/**
 * Relay an interop bundle from a source chain tx to a target chain.
 * Extracts the InteropBundleSent event from the source tx, then executes
 * the bundle on the target chain's InteropHandler.
 *
 * Usage:
 *   DEPLOYER_PK=0x... npx ts-node relay-bundle.ts <source-tx-hash> \
 *     --source-rpc <url> --target-rpc <url> \
 *     --source-ic <interop-center-addr> --target-ih <interop-handler-addr> \
 *     --source-chain-id <id>
 *
 * Or with named chains:
 *   DEPLOYER_PK=0x... npx ts-node relay-bundle.ts <source-tx-hash> \
 *     --from creator --to zksync_os
 */

import { Contract, ethers, providers, Wallet } from "ethers";
import { getAbi } from "./src/core/contracts";
import { INTEROP_BUNDLE_TUPLE_TYPE } from "./src/core/const";

// Known chain configs
const KNOWN_CHAINS: Record<string, { chainId: number; rpcUrl: string; addresses: Record<string, string> }> = {
  creator: {
    chainId: 278701,
    rpcUrl: "https://rpc.testnet.oncreator.com",
    addresses: {
      interopCenter: "0x919c67c54E8444EdAAA11bB92bA20E4f7533A35e",
      interopHandler: "0xe0908Ec8e9EC657dB6577D967cfCA70149F31776",
    },
  },
  zksync_os: {
    chainId: 8022833,
    rpcUrl: "https://zksync-os-testnet-alpha.zksync.dev",
    addresses: {
      interopCenter: "0xd6F206De0BE84631Ce37dE84aDBB4f14B3fa34e5",
      interopHandler: "0xf8837db4dbcC143A37A34913b9CbcCDE9E27bd02",
    },
  },
  union: {
    chainId: 2905,
    rpcUrl: "https://zksync-os-testnet-union.zksync.dev",
    addresses: {
      interopCenter: "0xb926f57313629D9f0C91C410319C438fd59ACa34",
      interopHandler: "0xaE0d47c8db46c7ea56f4B6BbEA4Bf35cc563D894",
    },
  },
};

function parseArgs() {
  const args = process.argv.slice(2);
  const txHash = args[0];
  if (!txHash || txHash.startsWith("--")) {
    console.error("Usage: npx ts-node relay-bundle.ts <tx-hash> --from <chain> --to <chain>");
    process.exit(1);
  }

  const opts: Record<string, string> = {};
  for (let i = 1; i < args.length; i += 2) {
    opts[args[i].replace(/^--/, "")] = args[i + 1];
  }

  let sourceRpc: string, targetRpc: string, sourceIc: string, targetIh: string, sourceChainId: number;

  if (opts.from && opts.to) {
    const src = KNOWN_CHAINS[opts.from];
    const tgt = KNOWN_CHAINS[opts.to];
    if (!src) { console.error(`Unknown chain: ${opts.from}. Known: ${Object.keys(KNOWN_CHAINS).join(", ")}`); process.exit(1); }
    if (!tgt) { console.error(`Unknown chain: ${opts.to}. Known: ${Object.keys(KNOWN_CHAINS).join(", ")}`); process.exit(1); }
    sourceRpc = src.rpcUrl;
    targetRpc = tgt.rpcUrl;
    sourceIc = src.addresses.interopCenter;
    targetIh = tgt.addresses.interopHandler;
    sourceChainId = src.chainId;
  } else {
    sourceRpc = opts["source-rpc"];
    targetRpc = opts["target-rpc"];
    sourceIc = opts["source-ic"];
    targetIh = opts["target-ih"];
    sourceChainId = parseInt(opts["source-chain-id"]);
  }

  if (!sourceRpc || !targetRpc || !sourceIc || !targetIh || !sourceChainId) {
    console.error("Missing args. Use --from/--to for named chains, or provide all --source-*/--target-* flags.");
    process.exit(1);
  }

  return { txHash, sourceRpc, targetRpc, sourceIc, targetIh, sourceChainId };
}

async function main() {
  const pk = process.env.DEPLOYER_PK;
  if (!pk) { console.error("Set DEPLOYER_PK"); process.exit(1); }

  const { txHash, sourceRpc, targetRpc, sourceIc, targetIh, sourceChainId } = parseArgs();

  const sourceProvider = new providers.JsonRpcProvider(sourceRpc);
  const targetProvider = new providers.JsonRpcProvider(targetRpc);
  const targetWallet = new Wallet(pk, targetProvider);

  // Step 1: Get source tx receipt and extract bundle
  console.log(`Fetching tx ${txHash}...`);
  const receipt = await sourceProvider.getTransactionReceipt(txHash);
  if (!receipt) { console.error("Transaction not found"); process.exit(1); }
  if (receipt.status !== 1) { console.error("Source tx failed"); process.exit(1); }

  const ic = new Contract(sourceIc, getAbi("InteropCenter"), sourceProvider);
  let interopBundle: unknown = null;
  for (const log of receipt.logs) {
    try {
      const parsed = ic.interface.parseLog({ topics: log.topics as string[], data: log.data });
      if (parsed?.name === "InteropBundleSent") {
        // eslint-disable-next-line @typescript-eslint/no-explicit-any
        interopBundle = (parsed.args as any).interopBundle;
        break;
      }
    } catch { /* skip */ }
  }
  if (!interopBundle) { console.error("InteropBundleSent event not found in tx"); process.exit(1); }
  console.log("Bundle extracted.");

  // Step 2: Execute on target
  const ih = new Contract(targetIh, getAbi("InteropHandler"), targetWallet);
  const abiCoder = ethers.utils.defaultAbiCoder;
  const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);

  const mockProof = {
    chainId: sourceChainId,
    l1BatchNumber: 0,
    l2MessageIndex: 0,
    message: { txNumberInBatch: 0, sender: sourceIc, data: "0x" },
    proof: [],
  };

  const gasPrice = await targetProvider.getGasPrice();
  const overrides = { gasPrice: gasPrice.mul(2), gasLimit: 30_000_000, type: 0 };

  console.log(`Executing bundle on target chain...`);
  try {
    const execTx = await ih.executeBundle(bundleData, mockProof, overrides);
    const execReceipt = await execTx.wait();
    console.log(`\nTx:     ${execTx.hash}`);
    console.log(`Status: ${execReceipt.status === 1 ? "SUCCESS" : "FAILED"}`);
    console.log(`Gas:    ${execReceipt.gasUsed.toString()}`);
    console.log(`Trace:  cast run ${execTx.hash} --rpc-url ${targetRpc}`);

    // Check for ShadowAccountDeployed event
    const shadowTopic = ethers.utils.id("ShadowAccountDeployed(address,uint256,address)");
    for (const log of execReceipt.logs) {
      if (log.topics[0] === shadowTopic) {
        console.log(`\nShadowAccount deployed: ${ethers.utils.defaultAbiCoder.decode(["address"], log.topics[1])[0]}`);
      }
    }
  } catch (error: unknown) {
    const msg = (error as Error)?.message || String(error);
    const failedTx = (error as { transactionHash?: string })?.transactionHash;
    console.error(`\nExecution failed: ${msg.slice(0, 200)}`);
    if (failedTx) {
      console.log(`Tx:    ${failedTx}`);
      console.log(`Trace: cast run ${failedTx} --rpc-url ${targetRpc}`);
    }
  }
}

main().catch((err) => { console.error(err.message || err); process.exit(1); });

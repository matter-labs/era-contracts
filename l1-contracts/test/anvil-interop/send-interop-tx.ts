#!/usr/bin/env node

import { ethers, providers, Wallet, Contract } from "ethers";
import { DeploymentRunner } from "./src/deployment-runner";
import { interopCenterAbi } from "./src/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, CONTRACT_DEPLOYER_ADDR, INTEROP_CENTER_ADDR } from "./src/const";

/**
 * Encode a chain ID in ERC-7930 format (EVM chain without address)
 * Format: version(2) + chainType(2) + chainRefLen(1) + chainRef(N) + addrLen(1)
 */
function encodeEvmChain(chainId: number): string {
  // Compact encoding: remove leading zeros from chain ID
  let chainIdHex = chainId.toString(16);
  if (chainIdHex.length % 2 !== 0) {
    chainIdHex = "0" + chainIdHex;
  }
  const chainRefBytes = ethers.utils.arrayify("0x" + chainIdHex);
  const chainRefLen = chainRefBytes.length;

  // Format: 0x00010000 (version 1, EVM chain) + chainRefLen + chainRef + 0x00 (no address)
  return ethers.utils.hexlify(
    new Uint8Array([
      0x00,
      0x01, // version 1
      0x00,
      0x00, // EVM chain type
      chainRefLen, // chain reference length
      ...chainRefBytes, // chain reference
      0x00, // address length (no address)
    ])
  );
}

/**
 * Encode an address in ERC-7930 format (EVM address without chain reference)
 * Format: version(2) + chainType(2) + chainRefLen(1) + addrLen(1) + addr(20)
 */
function encodeEvmAddress(address: string): string {
  const addrBytes = ethers.utils.arrayify(address);
  // Format: 0x000100000014 (version 1, EVM, no chain ref, 20-byte address) + address
  return ethers.utils.hexlify(
    new Uint8Array([
      0x00,
      0x01, // version 1
      0x00,
      0x00, // EVM chain type
      0x00, // chain reference length (no chain ref)
      0x14, // address length (20 bytes)
      ...addrBytes, // address
    ])
  );
}

/**
 * Send a cross-chain message from one L2 chain to another L2 chain using InteropCenter
 * This demonstrates L2→L2 interop messaging
 *
 * Usage:
 *   yarn send:interop [sourceChainId] [targetChainId] [targetAddress] [calldata]
 *
 * Example:
 *   yarn send:interop 10 12 0x1234... 0xabcd...
 *   yarn send:interop  # Uses defaults: 10 -> 12
 */
async function main() {
  console.log("\n=== Sending L2→L2 Cross-Chain Message via InteropCenter ===\n");

  const runner = new DeploymentRunner();
  const state = runner.loadState();

  if (!state.chains?.l2) {
    throw new Error("L2 chains not found. Run 'yarn step1' first.");
  }

  // Parse arguments
  const sourceChainId = process.argv[2] ? parseInt(process.argv[2]) : 10;
  const targetChainId = process.argv[3] ? parseInt(process.argv[3]) : 12;
  const targetAddress = process.argv[4] || CONTRACT_DEPLOYER_ADDR; // ContractDeployer
  const targetCalldata = process.argv[5] || "0x"; // Empty calldata

  // Verify chains exist
  const sourceChain = state.chains.l2.find((c) => c.chainId === sourceChainId);
  const targetChain = state.chains.l2.find((c) => c.chainId === targetChainId);

  if (!sourceChain) {
    throw new Error(`Source chain ${sourceChainId} not found`);
  }
  if (!targetChain) {
    throw new Error(`Target chain ${targetChainId} not found`);
  }

  console.log("Configuration:");
  console.log(`  Source Chain: ${sourceChainId} at ${sourceChain.rpcUrl}`);
  console.log(`  Target Chain: ${targetChainId} at ${targetChain.rpcUrl}`);
  console.log(`  Target Address: ${targetAddress}`);
  console.log(`  Target Calldata: ${targetCalldata}`);
  console.log();

  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
  const sourceProvider = new providers.JsonRpcProvider(sourceChain.rpcUrl);
  const wallet = new Wallet(privateKey, sourceProvider);

  const interopCenter = new Contract(INTEROP_CENTER_ADDR, interopCenterAbi(), wallet);

  // Encode destination chain ID in ERC-7930 format (EVM chain without address)
  const destinationChainIdBytes = encodeEvmChain(targetChainId);

  // Encode target address in ERC-7930 format (EVM address without chain reference)
  const targetAddressBytes = encodeEvmAddress(targetAddress);

  // Create call starter with ERC-7930 format
  const callStarter = {
    to: targetAddressBytes, // ERC-7930 encoded address
    data: targetCalldata,
    callAttributes: [], // No call attributes
  };

  const bundleAttributes: string[] = []; // No attributes for now

  console.log("📝 Preparing InteropCenter.sendBundle() call...");
  console.log(`   InteropCenter: ${INTEROP_CENTER_ADDR}`);
  console.log(`   Destination Chain: ${targetChainId} (encoded: ${destinationChainIdBytes})`);
  console.log(`   Target Address: ${targetAddress} (encoded: ${targetAddressBytes})`);
  console.log();

  // Get target chain provider and starting block BEFORE sending to avoid missing the relayed tx
  const targetProvider = new providers.JsonRpcProvider(targetChain.rpcUrl);
  const startBlock = await targetProvider.getBlockNumber();

  console.log("🚀 Sending cross-chain message via InteropCenter...");

  try {
    const tx = await interopCenter.sendBundle(destinationChainIdBytes, [callStarter], bundleAttributes, {
      gasLimit: 500000,
    });

    console.log(`   Transaction sent: ${tx.hash}`);
    console.log("   Waiting for confirmation...");

    const receipt = await tx.wait();
    console.log(`   ✅ Transaction confirmed in block ${receipt?.blockNumber}`);

    // Parse InteropBundleSent event
    console.log();
    console.log("📋 Transaction Events:");
    if (receipt && receipt.logs) {
      for (const log of receipt.logs) {
        try {
          const parsed = interopCenter.interface.parseLog({
            topics: log.topics as string[],
            data: log.data,
          });
          if (parsed && parsed.name === "InteropBundleSent") {
            console.log("   ✅ InteropBundleSent event emitted");
            console.log(`      Bundle Hash: ${parsed.args.interopBundleHash}`);
            console.log(`      L2→L1 Msg Hash: ${parsed.args.l2l1MsgHash}`);
          }
        } catch (e) {
          // Not an InteropCenter event
        }
      }
    }

    console.log();
    console.log("=== ✅ L2→L2 Message Sent ===");
    console.log(`Source Chain: ${sourceChainId}`);
    console.log(`Source Tx:    ${tx.hash}`);
    console.log();

    // Wait for relaying to complete
    console.log("⏳ Waiting for L2→L2 relayer to process message...");
    console.log("   (This typically takes 2-5 seconds)");
    let targetTxHash: string | null = null;
    let attempts = 0;
    const maxAttempts = 20; // 20 seconds max wait

    while (!targetTxHash && attempts < maxAttempts) {
      await new Promise((resolve) => setTimeout(resolve, 1000));
      attempts++;

      const currentBlock = await targetProvider.getBlockNumber();

      // Check recent blocks for transactions to the target address
      for (let i = startBlock; i <= currentBlock; i++) {
        const block = await targetProvider.getBlock(i);
        if (block && block.transactions) {
          for (const txHash of block.transactions) {
            const tx = await targetProvider.getTransaction(txHash as string);
            if (tx && tx.to?.toLowerCase() === targetAddress.toLowerCase()) {
              // Check if data matches (accounting for possible encoding differences)
              if (targetCalldata === "0x" || tx.data.toLowerCase().includes(targetCalldata.slice(2).toLowerCase())) {
                targetTxHash = txHash as string;
                break;
              }
            }
          }
        }
        if (targetTxHash) break;
      }
    }

    console.log();
    if (targetTxHash) {
      console.log("=== ✅ L2→L2 Message Relayed ===");
      console.log(`Target Chain:  ${targetChainId}`);
      console.log(`Target Tx:     ${targetTxHash}`);
      console.log();
      console.log("✅ Cross-chain message successfully relayed!");
      console.log();
      console.log("To see the full trace:");
      console.log(`  cast run ${tx.hash} -r ${sourceChain.rpcUrl}`);
      console.log(`  cast run ${targetTxHash} -r ${targetChain.rpcUrl}`);
    } else {
      console.log("⚠️  Timeout waiting for relay (message may still be processing)");
      console.log("   Check daemon logs: tail -f /tmp/step6-output.log");
    }
  } catch (error: unknown) {
    const err = error as Error & { data?: string };
    console.error("\n❌ Transaction failed:");
    console.error(`   ${err.message}`);

    if (err.data) {
      console.error(`   Error data: ${err.data}`);
    }

    throw error;
  }
}

main().catch((error) => {
  console.error("❌ Failed:", error);
  process.exit(1);
});

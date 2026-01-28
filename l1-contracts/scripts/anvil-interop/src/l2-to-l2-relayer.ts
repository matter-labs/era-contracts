import type { JsonRpcProvider } from "ethers";
import { Contract, Wallet, AbiCoder } from "ethers";
import type { ChainAddresses, CoreDeployedAddresses } from "./types";
import { sleep } from "./utils";

/**
 * L2→L2 Cross-Chain Relayer
 *
 * Monitors L2 chains for special cross-chain message transactions and relays them
 * through L1 to the target L2 chain.
 *
 * Flow: L2 Source → L1 Bridgehub → L2 Target
 *
 * To send a cross-chain message from L2, send a transaction to a special marker address:
 * - To: 0x0000000000000000000000000000000000000420 (CROSS_CHAIN_MESSENGER)
 * - Data: ABI-encoded (targetChainId, targetAddress, targetCalldata)
 */
export class L2ToL2Relayer {
  private l1Provider: JsonRpcProvider;
  private l2Providers: Map<number, JsonRpcProvider>;
  private l1Wallet: Wallet;
  private l1Addresses: CoreDeployedAddresses;
  private chainAddresses: Map<number, ChainAddresses>;
  private isRunning: boolean = false;
  private pollingInterval: number = 2000; // 2 seconds
  private lastProcessedBlocks: Map<number, number> = new Map();
  private processedTxHashes: Set<string> = new Set();

  // InteropCenter system contract address
  private readonly INTEROP_CENTER_ADDR = "0x000000000000000000000000000000000001000d";

  // InteropBundleSent event signature
  // event InteropBundleSent(bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle interopBundle)
  private readonly INTEROP_BUNDLE_SENT_TOPIC = "0xd5e1642d9c6ff371d1f102384c70a9a38530493e4747a53919f128685013cb6e";

  constructor(
    l1Provider: JsonRpcProvider,
    l2Providers: Map<number, JsonRpcProvider>,
    privateKey: string,
    l1Addresses: CoreDeployedAddresses,
    chainAddresses: Map<number, ChainAddresses>,
    pollingIntervalMs: number = 2000
  ) {
    this.l1Provider = l1Provider;
    this.l2Providers = l2Providers;
    this.l1Wallet = new Wallet(privateKey, l1Provider);
    this.l1Addresses = l1Addresses;
    this.chainAddresses = chainAddresses;
    this.pollingInterval = pollingIntervalMs;

    // Initialize last processed blocks for each L2
    for (const chainId of l2Providers.keys()) {
      this.lastProcessedBlocks.set(chainId, 0);
    }
  }

  async start(): Promise<void> {
    console.log("🌉 Starting L2→L2 Cross-Chain Relayer...");

    // Get current block numbers as starting points
    for (const [chainId, provider] of this.l2Providers.entries()) {
      const blockNumber = await provider.getBlockNumber();
      this.lastProcessedBlocks.set(chainId, blockNumber);
      console.log(`   Starting from L2 chain ${chainId} block ${blockNumber}`);
    }

    this.isRunning = true;

    // Start polling loop
    this.poll();

    console.log("✅ L2→L2 Relayer started");
  }

  async stop(): Promise<void> {
    console.log("🛑 Stopping L2→L2 Cross-Chain Relayer...");
    this.isRunning = false;
    console.log("✅ L2→L2 Relayer stopped");
  }

  private async poll(): Promise<void> {
    while (this.isRunning) {
      try {
        await this.processAllChains();
      } catch (error) {
        console.error("❌ L2→L2 Relayer error:", error);
      }

      await sleep(this.pollingInterval);
    }
  }

  private async processAllChains(): Promise<void> {
    for (const [sourceChainId, provider] of this.l2Providers.entries()) {
      await this.processChain(sourceChainId, provider);
    }
  }

  private async processChain(sourceChainId: number, provider: JsonRpcProvider): Promise<void> {
    const currentBlock = await provider.getBlockNumber();
    const lastProcessed = this.lastProcessedBlocks.get(sourceChainId) || 0;

    if (currentBlock <= lastProcessed) {
      return;
    }

    const fromBlock = lastProcessed + 1;
    const toBlock = currentBlock;

    // Process blocks in batches to avoid overwhelming the RPC
    const batchSize = 10;
    for (let start = fromBlock; start <= toBlock; start += batchSize) {
      const end = Math.min(start + batchSize - 1, toBlock);
      await this.processBlockRange(sourceChainId, provider, start, end);
    }

    this.lastProcessedBlocks.set(sourceChainId, currentBlock);
  }

  private async processBlockRange(
    sourceChainId: number,
    provider: JsonRpcProvider,
    fromBlock: number,
    toBlock: number
  ): Promise<void> {
    for (let blockNum = fromBlock; blockNum <= toBlock; blockNum++) {
      const block = await provider.getBlock(blockNum, true);

      if (!block || !block.transactions) {
        continue;
      }

      for (const txHash of block.transactions) {
        await this.processTransaction(sourceChainId, provider, txHash as string);
      }
    }
  }

  private async processTransaction(
    sourceChainId: number,
    provider: JsonRpcProvider,
    txHash: string
  ): Promise<void> {
    // Skip if already processed
    if (this.processedTxHashes.has(txHash)) {
      return;
    }

    // Get transaction receipt to check for InteropBundleSent event
    const receipt = await provider.getTransactionReceipt(txHash);

    if (!receipt || !receipt.logs) {
      return;
    }

    // Check if any log is an InteropBundleSent event from InteropCenter
    let foundInteropEvent = false;
    let interopEventLog: any = null;

    for (const log of receipt.logs) {
      if (
        log.address.toLowerCase() === this.INTEROP_CENTER_ADDR.toLowerCase() &&
        log.topics[0] === this.INTEROP_BUNDLE_SENT_TOPIC
      ) {
        foundInteropEvent = true;
        interopEventLog = log;
        break;
      }
    }

    if (!foundInteropEvent) {
      return;
    }

    console.log(`\n   🔗 Found L2→L2 cross-chain message on chain ${sourceChainId}`);
    console.log(`      Source Tx Hash: ${txHash}`);

    try {
      await this.relayCrossChainMessage(sourceChainId, txHash, interopEventLog, provider);
      this.processedTxHashes.add(txHash);
      console.log(`      ✅ Cross-chain message relayed`);
    } catch (error: any) {
      console.error(`      ❌ Failed to relay message:`, error.message);
    }
  }

  private async relayCrossChainMessage(
    sourceChainId: number,
    sourceTxHash: string,
    interopEventLog: any,
    sourceProvider: JsonRpcProvider
  ): Promise<void> {
    // Parse InteropBundleSent event to extract destination chain and calls
    const abiCoder = AbiCoder.defaultAbiCoder();

    // InteropBundleSent event structure:
    // event InteropBundleSent(bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle interopBundle)
    // InteropBundle: (bytes32 canonicalHash, bytes32 chainTreeRoot, bytes32 destination, uint256 nonce, InteropCallStarter[] calls)
    // InteropCallStarter: (address target, uint256 value, bytes data)

    let targetChainId: number;
    let calls: Array<{ target: string; value: bigint; data: string }>;

    try {
      // The third parameter (index 2) in the event is the InteropBundle struct
      // Data field contains the non-indexed parameters
      const decodedData = abiCoder.decode(
        [
          "bytes32", // l2l1MsgHash
          "bytes32", // interopBundleHash
          "tuple(bytes1,uint256,uint256,bytes32,tuple(bytes1,bool,address,address,uint256,bytes)[],tuple(bytes,bytes))", // InteropBundle
        ],
        interopEventLog.data
      );

      const interopBundle = decodedData[2];
      targetChainId = Number(interopBundle[2]); // bytes32 destination
      const rawCalls = interopBundle[4]; // InteropCallStarter[] calls (as arrays)

      // Decode destination (uint256 encoded as bytes32)
      // destinationChainId extracted above

      // Convert tuple arrays to objects
      calls = rawCalls.map((call: any) => ({
        target: call[2], // address to (index 2) // address
        value: call[4],  // uint256 value (index 4)  // uint256
        data: call[5],   // bytes data (index 5)   // bytes
      }));

      console.log(`      From Chain: ${sourceChainId}`);
      console.log(`      To Chain: ${targetChainId}`);
      console.log(`      Calls: ${calls.length}`);

      for (let i = 0; i < calls.length; i++) {
        console.log(`      Call ${i + 1}: ${calls[i].target} with ${calls[i].data.length} bytes data`);
      }
    } catch (error) {
      console.error(`      Failed to decode InteropBundleSent event:`, error);
      return;
    }

    // Verify target chain exists
    const targetProvider = this.l2Providers.get(targetChainId);
    if (!targetProvider) {
      console.error(`      Target chain ${targetChainId} not found`);
      return;
    }

    console.log(`      Executing ${calls.length} call(s) on target L2 chain...`);

    // Direct execution on target L2 (bypassing L1 for Anvil testing)
    const targetWallet = new Wallet(this.l1Wallet.privateKey, targetProvider);

    // Execute each call in the bundle
    for (let i = 0; i < calls.length; i++) {
      const call = calls[i];
      const tx = await targetWallet.sendTransaction({
        to: call.target,
        value: call.value,
        data: call.data,
        gasLimit: 1000000,
      });

      console.log(`      L2 Target Tx ${i + 1}: ${tx.hash}`);

      const receipt = await tx.wait();
      console.log(`      Confirmed in L2 block ${receipt?.blockNumber}`);
    }
  }

  getStats(): { processedMessages: number; chainsMonitored: number } {
    return {
      processedMessages: this.processedTxHashes.size,
      chainsMonitored: this.l2Providers.size,
    };
  }
}

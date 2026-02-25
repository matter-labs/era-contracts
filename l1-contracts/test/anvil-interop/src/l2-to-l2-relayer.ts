import type { providers } from "ethers";
import { Contract, Wallet, utils } from "ethers";
import { sleep, loadAbiFromOut } from "./utils";
import {
  INTEROP_BUNDLE_SENT_TOPIC,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
} from "./const";

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
  private l2Providers: Map<number, providers.JsonRpcProvider>;
  private l1Wallet: Wallet;
  private isRunning: boolean = false;
  private pollingInterval: number = 2000; // 2 seconds
  private lastProcessedBlocks: Map<number, number> = new Map();
  private processedTxHashes: Set<string> = new Set();

  constructor(
    l1Provider: providers.JsonRpcProvider,
    l2Providers: Map<number, providers.JsonRpcProvider>,
    privateKey: string,
    pollingIntervalMs: number = 2000
  ) {
    this.l2Providers = l2Providers;
    this.l1Wallet = new Wallet(privateKey, l1Provider);
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

  private async processChain(sourceChainId: number, provider: providers.JsonRpcProvider): Promise<void> {
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
    provider: providers.JsonRpcProvider,
    fromBlock: number,
    toBlock: number
  ): Promise<void> {
    for (let blockNum = fromBlock; blockNum <= toBlock; blockNum++) {
      const block = await provider.getBlock(blockNum);

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
    provider: providers.JsonRpcProvider,
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
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let interopEventLog: any = null;

    for (const log of receipt.logs) {
      if (
        log.address.toLowerCase() === INTEROP_CENTER_ADDR.toLowerCase() &&
        log.topics[0] === INTEROP_BUNDLE_SENT_TOPIC
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
      await this.relayCrossChainMessage(sourceChainId, interopEventLog);
      this.processedTxHashes.add(txHash);
      console.log("      ✅ Cross-chain message relayed");
    } catch (error: unknown) {
      console.error("      ❌ Failed to relay message:", (error as Error).message);
    }
  }

  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  private async relayCrossChainMessage(sourceChainId: number, interopEventLog: any): Promise<void> {
    // Parse InteropBundleSent event to extract destination chain and calls
    const abiCoder = new utils.AbiCoder();

    // InteropBundleSent event structure:
    // event InteropBundleSent(bytes32 l2l1MsgHash, bytes32 interopBundleHash, InteropBundle interopBundle)
    // InteropBundle: (bytes32 canonicalHash, bytes32 chainTreeRoot, bytes32 destination, uint256 nonce, InteropCallStarter[] calls)
    // InteropCallStarter: (address target, uint256 value, bytes data)

    let targetChainId: number;
    let calls: Array<{ target: string; value: bigint; data: string }>;
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    let interopBundle: any;

    try {
      // The third parameter (index 2) in the event is the InteropBundle struct
      // Data field contains the non-indexed parameters
      const decodedData = abiCoder.decode(
        [
          "bytes32", // l2l1MsgHash
          "bytes32", // interopBundleHash
          INTEROP_BUNDLE_TUPLE_TYPE, // InteropBundle
        ],
        interopEventLog.data
      );

      interopBundle = decodedData[2];
      targetChainId = Number(interopBundle[2]); // uint256 destinationChainId
      const rawCalls = interopBundle[5]; // InteropCall[] calls

      // Decode destination (uint256 encoded as bytes32)
      // destinationChainId extracted above

      // Convert tuple arrays to objects
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      calls = rawCalls.map((call: any) => ({
        target: call[2], // address to (index 2) // address
        value: call[4], // uint256 value (index 4)  // uint256
        data: call[5], // bytes data (index 5)   // bytes
      }));

      console.log(`      From Chain: ${sourceChainId}`);
      console.log(`      To Chain: ${targetChainId}`);
      console.log(`      Calls: ${calls.length}`);

      for (let i = 0; i < calls.length; i++) {
        console.log(`      Call ${i + 1}: ${calls[i].target} with ${calls[i].data.length} bytes data`);
      }
    } catch (error) {
      console.error("      Failed to decode InteropBundleSent event:", error);
      return;
    }

    // Verify target chain exists
    const targetProvider = this.l2Providers.get(targetChainId);
    if (!targetProvider) {
      console.error(`      Target chain ${targetChainId} not found`);
      return;
    }

    console.log("      Executing bundle on target L2 chain via L2InteropHandler...");

    // For Anvil testing, we directly call L2InteropHandler.executeBundle()
    // In production, this would go through L1 settlement
    const targetWallet = new Wallet(this.l1Wallet.privateKey, targetProvider);

    // Encode the executeBundle call
    // For Anvil testing, we use an empty/mock proof since we're not doing full L1 settlement
    const mockProof = {
      chainId: sourceChainId,
      l1BatchNumber: 0,
      l2MessageIndex: 0,
      message: {
        txNumberInBatch: 0,
        sender: INTEROP_CENTER_ADDR,
        data: "0x",
      },
      proof: [],
    };

    const interopHandlerAbi = loadAbiFromOut("InteropHandler.sol/InteropHandler.json");

    const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, interopHandlerAbi, targetWallet);

    // Extract just the InteropBundle from the event data
    // The event emits (l2l1MsgHash, interopBundleHash, InteropBundle)
    // We need to extract and re-encode just the InteropBundle for executeBundle
    const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);

    try {
      const tx = await interopHandler.executeBundle(bundleData, mockProof, {
        gasLimit: 5000000,
      });

      console.log(`      L2 Target Tx: ${tx.hash}`);

      const receipt = await tx.wait();
      console.log(`      Confirmed in L2 block ${receipt?.blockNumber}`);
      console.log(`      Gas used: ${receipt?.gasUsed.toString()}`);
    } catch (error: unknown) {
      throw new Error(`Failed to execute bundle: ${(error as Error).message}`);
    }
  }

}

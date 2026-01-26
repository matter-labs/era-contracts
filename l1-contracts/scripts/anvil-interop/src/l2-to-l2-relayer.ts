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

  // Special marker address for cross-chain messages on L2
  private readonly CROSS_CHAIN_MESSENGER = "0x0000000000000000000000000000000000000420";

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

    const tx = await provider.getTransaction(txHash);

    if (!tx) {
      return;
    }

    // Check if this is a cross-chain message (sent to our special address)
    if (tx.to?.toLowerCase() !== this.CROSS_CHAIN_MESSENGER.toLowerCase()) {
      return;
    }

    console.log(`\n   🔗 Found L2→L2 cross-chain message on chain ${sourceChainId}`);
    console.log(`      Source Tx Hash: ${txHash}`);

    try {
      await this.relayCrossChainMessage(sourceChainId, tx);
      this.processedTxHashes.add(txHash);
      console.log(`      ✅ Cross-chain message relayed`);
    } catch (error: any) {
      console.error(`      ❌ Failed to relay message:`, error.message);
    }
  }

  private async relayCrossChainMessage(sourceChainId: number, sourceTx: any): Promise<void> {
    // Decode the cross-chain message data
    // Expected format: (uint256 targetChainId, address targetAddress, bytes targetCalldata)
    const abiCoder = AbiCoder.defaultAbiCoder();

    let targetChainId: number;
    let targetAddress: string;
    let targetCalldata: string;

    try {
      const decoded = abiCoder.decode(["uint256", "address", "bytes"], sourceTx.data);
      targetChainId = Number(decoded[0]);
      targetAddress = decoded[1];
      targetCalldata = decoded[2];

      console.log(`      From Chain: ${sourceChainId}`);
      console.log(`      To Chain: ${targetChainId}`);
      console.log(`      Target Address: ${targetAddress}`);
      console.log(`      Calldata Length: ${targetCalldata.length} bytes`);
    } catch (error) {
      console.error(`      Failed to decode cross-chain message:`, error);
      return;
    }

    // Verify target chain exists
    if (!this.chainAddresses.has(targetChainId)) {
      console.error(`      Target chain ${targetChainId} not found`);
      return;
    }

    // Send the message through L1 bridgehub
    const bridgehubAbi = [
      "function requestL2TransactionDirect(tuple(uint256 chainId, uint256 mintValue, address l2Contract, uint256 l2Value, bytes l2Calldata, uint256 l2GasLimit, uint256 l2GasPerPubdataByteLimit, bytes[] factoryDeps, address refundRecipient) _request) external payable returns (bytes32)",
    ];

    const bridgehub = new Contract(this.l1Addresses.bridgehub, bridgehubAbi, this.l1Wallet);

    const request = {
      chainId: targetChainId,
      mintValue: 0,
      l2Contract: targetAddress,
      l2Value: 0,
      l2Calldata: targetCalldata,
      l2GasLimit: 1000000,
      l2GasPerPubdataByteLimit: 800,
      factoryDeps: [],
      refundRecipient: this.l1Wallet.address,
    };

    console.log(`      Relaying through L1 bridgehub...`);

    const l1Tx = await bridgehub.requestL2TransactionDirect(request, {
      value: 0,
    });

    console.log(`      L1 Relay Tx: ${l1Tx.hash}`);

    await l1Tx.wait();
    console.log(`      L1 relay confirmed, L1→L2 relayer will execute on target chain`);
  }

  getStats(): { processedMessages: number; chainsMonitored: number } {
    return {
      processedMessages: this.processedTxHashes.size,
      chainsMonitored: this.l2Providers.size,
    };
  }
}

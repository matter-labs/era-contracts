import type { JsonRpcProvider, Log } from "ethers";
import { Contract, Wallet, AbiCoder, EventLog } from "ethers";
import type { ChainAddresses, CoreDeployedAddresses } from "./types";
import { sleep } from "./utils";

/**
 * L1→L2 Transaction Relayer
 *
 * Monitors L1 for NewPriorityRequest events from chain diamond proxies
 * and executes the corresponding L2 transactions on the target Anvil L2 chains.
 *
 * This simulates what a real ZKsync server would do - processing L1→L2 messages.
 */
export class L1ToL2Relayer {
  private l1Provider: JsonRpcProvider;
  private l2Providers: Map<number, JsonRpcProvider>;
  private l1Addresses: CoreDeployedAddresses;
  private chainAddresses: Map<number, ChainAddresses>;
  private privateKey: string;
  private isRunning: boolean = false;
  private pollingInterval: number = 2000; // 2 seconds
  private lastProcessedBlock: number = 0;
  private processedTxIds: Set<string> = new Set();

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
    this.privateKey = privateKey;
    this.l1Addresses = l1Addresses;
    this.chainAddresses = chainAddresses;
    this.pollingInterval = pollingIntervalMs;
  }

  async start(): Promise<void> {
    console.log("🌉 Starting L1→L2 Transaction Relayer...");

    // Get current block as starting point
    this.lastProcessedBlock = await this.l1Provider.getBlockNumber();
    console.log(`   Starting from L1 block ${this.lastProcessedBlock}`);

    this.isRunning = true;

    // Start polling loop (don't await - let it run in background)
    this.poll();

    console.log("✅ L1→L2 Relayer started");
  }

  async stop(): Promise<void> {
    console.log("🛑 Stopping L1→L2 Transaction Relayer...");
    this.isRunning = false;
    console.log("✅ L1→L2 Relayer stopped");
  }

  private async poll(): Promise<void> {
    while (this.isRunning) {
      try {
        await this.processNewBlocks();
      } catch (error) {
        console.error("❌ L1→L2 Relayer error:", error);
      }

      await sleep(this.pollingInterval);
    }
  }

  private async processNewBlocks(): Promise<void> {
    const currentBlock = await this.l1Provider.getBlockNumber();

    if (currentBlock <= this.lastProcessedBlock) {
      return;
    }

    console.log(`\n📊 L1→L2 Relayer: Processing L1 blocks ${this.lastProcessedBlock + 1} to ${currentBlock}`);

    // Process bridgehub transactions directly (more reliable than events on Anvil)
    await this.processBridgehubTransactions(this.lastProcessedBlock + 1, currentBlock);

    this.lastProcessedBlock = currentBlock;
  }

  private async processBridgehubTransactions(
    fromBlock: number,
    toBlock: number
  ): Promise<void> {
    // ABI for requestL2TransactionDirect function
    const bridgehubAbi = [
      "function requestL2TransactionDirect(tuple(uint256 chainId, uint256 mintValue, address l2Contract, uint256 l2Value, bytes l2Calldata, uint256 l2GasLimit, uint256 l2GasPerPubdataByteLimit, bytes[] factoryDeps, address refundRecipient) _request) external payable returns (bytes32)",
    ];

    const bridgehub = new Contract(this.l1Addresses.bridgehub, bridgehubAbi, this.l1Provider);
    const iface = bridgehub.interface;

    try {
      // Get all blocks in range and check for transactions to bridgehub
      for (let blockNum = fromBlock; blockNum <= toBlock; blockNum++) {
        const block = await this.l1Provider.getBlock(blockNum, true);

        if (!block || !block.transactions) {
          continue;
        }

        for (const txHash of block.transactions) {
          const tx = await this.l1Provider.getTransaction(txHash as string);

          if (!tx || tx.to?.toLowerCase() !== this.l1Addresses.bridgehub.toLowerCase()) {
            continue;
          }

          // Try to decode as requestL2TransactionDirect call
          try {
            const decoded = iface.parseTransaction({ data: tx.data, value: tx.value });

            if (decoded && decoded.name === "requestL2TransactionDirect") {
              await this.processL1ToL2Transaction(txHash as string, decoded.args[0]);
            }
          } catch {
            // Not a requestL2TransactionDirect call, skip
          }
        }
      }
    } catch (error) {
      console.error(`   Failed to process bridgehub transactions:`, error);
    }
  }

  private async processL1ToL2Transaction(txHash: string, request: any): Promise<void> {
    const chainId = Number(request.chainId);

    // Create unique key for deduplication
    const txKey = `${chainId}-${txHash}`;
    if (this.processedTxIds.has(txKey)) {
      return;
    }

    console.log(`\n   ⚡ Processing L1→L2 transaction for chain ${chainId}`);
    console.log(`      L1 Tx Hash: ${txHash}`);

    try {
      await this.executeOnL2(chainId, request);
      this.processedTxIds.add(txKey);
      console.log(`      ✅ L1→L2 transaction executed on chain ${chainId}`);
    } catch (error: any) {
      console.error(`      ❌ Failed to execute L1→L2 transaction on chain ${chainId}:`, error.message);
    }
  }

  private async executeOnL2(
    chainId: number,
    request: any
  ): Promise<void> {
    const l2Provider = this.l2Providers.get(chainId);
    if (!l2Provider) {
      throw new Error(`L2 provider not found for chain ${chainId}`);
    }

    const l2Wallet = new Wallet(this.privateKey, l2Provider);

    // Extract L2 transaction details from request
    const toAddress = request.l2Contract;
    const value = request.l2Value;
    const data = request.l2Calldata;
    const gasLimit = request.l2GasLimit;

    console.log(`      Target: ${toAddress}`);
    console.log(`      Value: ${value.toString()}`);
    console.log(`      GasLimit: ${gasLimit.toString()}`);
    console.log(`      Data: ${data}`);

    // Send the transaction on L2
    const tx = await l2Wallet.sendTransaction({
      to: toAddress,
      value: value,
      data: data,
      gasLimit: gasLimit,
    });

    console.log(`      L2 Tx Hash: ${tx.hash}`);

    const receipt = await tx.wait();
    console.log(`      Confirmed in L2 block ${receipt?.blockNumber}`);

    // TODO: Handle factory deps if needed
    const factoryDeps = request.factoryDeps;
    if (factoryDeps && factoryDeps.length > 0) {
      console.log(`      Note: ${factoryDeps.length} factory deps were included but not deployed`);
    }
  }

  getStats(): { processedTxs: number; lastBlock: number } {
    return {
      processedTxs: this.processedTxIds.size,
      lastBlock: this.lastProcessedBlock,
    };
  }
}

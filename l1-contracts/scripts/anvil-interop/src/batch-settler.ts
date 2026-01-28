import type { JsonRpcProvider } from "ethers";
import { Contract, Wallet, keccak256, toUtf8Bytes, AbiCoder } from "ethers";
import type { BatchState, L2Transaction, CommitBatchInfo, StoredBatchInfo, ProofInput, ChainAddresses } from "./types";
import { sleep } from "./utils";

export class BatchSettler {
  private l1Provider: JsonRpcProvider;
  private l2Providers: Map<number, JsonRpcProvider>;
  private wallet: Wallet;
  private batchStates: Map<number, BatchState> = new Map();
  private pollingInterval: number = 5000;
  private batchSizeLimit: number = 10;
  private isRunning: boolean = false;
  private chainAddresses: Map<number, ChainAddresses>;

  constructor(
    l1Provider: JsonRpcProvider,
    l2Providers: Map<number, JsonRpcProvider>,
    privateKey: string,
    chainAddresses: Map<number, ChainAddresses>,
    pollingIntervalMs: number = 5000,
    batchSizeLimit: number = 10
  ) {
    this.l1Provider = l1Provider;
    this.l2Providers = l2Providers;
    this.wallet = new Wallet(privateKey, l1Provider);
    this.chainAddresses = chainAddresses;
    this.pollingInterval = pollingIntervalMs;
    this.batchSizeLimit = batchSizeLimit;

    for (const chainId of l2Providers.keys()) {
      this.batchStates.set(chainId, {
        chainId,
        lastCommitted: 0,
        lastProved: 0,
        lastExecuted: 0,
        pendingTxs: [],
      });
    }
  }

  async start(): Promise<void> {
    console.log("🔄 Starting batch settler daemon...");
    this.isRunning = true;

    this.poll();

    console.log("✅ Batch settler daemon started");
  }

  async stop(): Promise<void> {
    console.log("🛑 Stopping batch settler daemon...");
    this.isRunning = false;
    console.log("✅ Batch settler daemon stopped");
  }

  private async poll(): Promise<void> {
    while (this.isRunning) {
      try {
        for (const [chainId, provider] of this.l2Providers.entries()) {
          await this.processChain(chainId, provider);
        }
      } catch (error) {
        console.error("❌ Batch settler error:", error);
      }

      await sleep(this.pollingInterval);
    }
  }

  private async processChain(chainId: number, provider: JsonRpcProvider): Promise<void> {
    const state = this.batchStates.get(chainId);
    if (!state) {
      return;
    }

    const latestBlock = await provider.getBlockNumber();
    const lastProcessedBlock = state.lastCommitted;

    if (latestBlock <= lastProcessedBlock) {
      return;
    }

    console.log(`📊 Chain ${chainId}: Processing blocks ${lastProcessedBlock + 1} to ${latestBlock}`);

    for (let blockNumber = lastProcessedBlock + 1; blockNumber <= latestBlock; blockNumber++) {
      const block = await provider.getBlock(blockNumber, true);

      if (block && block.transactions) {
        for (const txHash of block.transactions) {
          const tx = await provider.getTransaction(txHash as string);
          if (tx) {
            state.pendingTxs.push({
              from: tx.from,
              to: tx.to || "",
              value: tx.value.toString(),
              data: tx.data,
              gasLimit: tx.gasLimit.toString(),
              maxFeePerGas: tx.maxFeePerGas?.toString() || "0",
              maxPriorityFeePerGas: tx.maxPriorityFeePerGas?.toString() || "0",
              nonce: tx.nonce,
              hash: tx.hash,
              blockNumber: blockNumber,
            });
          }
        }
      }
    }

    if (state.pendingTxs.length >= this.batchSizeLimit) {
      await this.commitBatch(chainId);
    }

    if (state.lastProved < state.lastCommitted) {
      await this.proveBatch(chainId);
    }

    if (state.lastExecuted < state.lastProved) {
      await this.executeBatch(chainId);
    }
  }

  private async commitBatch(chainId: number): Promise<void> {
    const state = this.batchStates.get(chainId);
    if (!state || state.pendingTxs.length === 0) {
      return;
    }

    console.log(`📝 Committing batch for chain ${chainId}...`);

    try {
      const chainAddresses = this.chainAddresses.get(chainId);
      if (!chainAddresses) {
        throw new Error(`Chain addresses not found for chain ${chainId}`);
      }

      const executorAbi = [
        "function commitBatchesSharedBridge(uint256 chainId, tuple(uint64 batchNumber, bytes32 batchHash, uint64 indexRepeatedStorageChanges, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 l2LogsTreeRoot, uint256 timestamp, bytes32 commitment) storedBatchInfo, tuple(uint64 batchNumber, uint256 timestamp, uint64 indexRepeatedStorageChanges, bytes32 newStateRoot, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 bootloaderHeapInitialContentsHash, bytes32 eventsQueueStateHash, bytes systemLogs, bytes operatorDAInput)[] commitBatchInfos) external",
      ];

      const executor = new Contract(chainAddresses.diamondProxy, executorAbi, this.wallet);

      const batchNumber = state.lastCommitted + 1;
      const commitBatchInfo = this.buildCommitBatchInfo(batchNumber, state.pendingTxs);

      const storedBatchInfo: StoredBatchInfo = {
        batchNumber: BigInt(state.lastCommitted),
        batchHash: keccak256(toUtf8Bytes(`batch-${state.lastCommitted}`)),
        indexRepeatedStorageChanges: 0n,
        numberOfLayer1Txs: 0n,
        priorityOperationsHash: keccak256(toUtf8Bytes("empty")),
        l2LogsTreeRoot: keccak256(toUtf8Bytes("logs")),
        timestamp: BigInt(Math.floor(Date.now() / 1000)),
        commitment: keccak256(toUtf8Bytes(`commitment-${state.lastCommitted}`)),
      };

      const tx = await executor.commitBatchesSharedBridge(chainId, storedBatchInfo, [commitBatchInfo]);

      await tx.wait();

      state.lastCommitted = Number(batchNumber);
      state.pendingTxs = [];

      console.log(`✅ Batch ${batchNumber} committed for chain ${chainId}`);
    } catch (error) {
      console.error(`❌ Failed to commit batch for chain ${chainId}:`, error);
    }
  }

  private async proveBatch(chainId: number): Promise<void> {
    const state = this.batchStates.get(chainId);
    if (!state) {
      return;
    }

    console.log(`🔍 Proving batch for chain ${chainId}...`);

    try {
      const chainAddresses = this.chainAddresses.get(chainId);
      if (!chainAddresses) {
        throw new Error(`Chain addresses not found for chain ${chainId}`);
      }

      const executorAbi = [
        "function proveBatchesSharedBridge(uint256 chainId, tuple(uint64 batchNumber, bytes32 batchHash, uint64 indexRepeatedStorageChanges, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 l2LogsTreeRoot, uint256 timestamp, bytes32 commitment) prevBatch, tuple(uint64 batchNumber, bytes32 batchHash, uint64 indexRepeatedStorageChanges, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 l2LogsTreeRoot, uint256 timestamp, bytes32 commitment)[] committedBatches, tuple(uint256[] recursiveAggregationInput, uint256[] serializedProof) proof) external",
      ];

      const executor = new Contract(chainAddresses.diamondProxy, executorAbi, this.wallet);

      const batchNumber = state.lastProved + 1;

      const prevBatch: StoredBatchInfo = {
        batchNumber: BigInt(state.lastProved),
        batchHash: keccak256(toUtf8Bytes(`batch-${state.lastProved}`)),
        indexRepeatedStorageChanges: 0n,
        numberOfLayer1Txs: 0n,
        priorityOperationsHash: keccak256(toUtf8Bytes("empty")),
        l2LogsTreeRoot: keccak256(toUtf8Bytes("logs")),
        timestamp: BigInt(Math.floor(Date.now() / 1000)),
        commitment: keccak256(toUtf8Bytes(`commitment-${state.lastProved}`)),
      };

      const committedBatch: StoredBatchInfo = {
        batchNumber: BigInt(batchNumber),
        batchHash: keccak256(toUtf8Bytes(`batch-${batchNumber}`)),
        indexRepeatedStorageChanges: 0n,
        numberOfLayer1Txs: 0n,
        priorityOperationsHash: keccak256(toUtf8Bytes("empty")),
        l2LogsTreeRoot: keccak256(toUtf8Bytes("logs")),
        timestamp: BigInt(Math.floor(Date.now() / 1000)),
        commitment: keccak256(toUtf8Bytes(`commitment-${batchNumber}`)),
      };

      const proof = this.generateMockProof();

      const tx = await executor.proveBatchesSharedBridge(chainId, prevBatch, [committedBatch], proof);

      await tx.wait();

      state.lastProved = batchNumber;

      console.log(`✅ Batch ${batchNumber} proved for chain ${chainId}`);
    } catch (error) {
      console.error(`❌ Failed to prove batch for chain ${chainId}:`, error);
    }
  }

  private async executeBatch(chainId: number): Promise<void> {
    const state = this.batchStates.get(chainId);
    if (!state) {
      return;
    }

    console.log(`⚡ Executing batch for chain ${chainId}...`);

    try {
      const chainAddresses = this.chainAddresses.get(chainId);
      if (!chainAddresses) {
        throw new Error(`Chain addresses not found for chain ${chainId}`);
      }

      const executorAbi = [
        "function executeBatchesSharedBridge(uint256 chainId, tuple(uint64 batchNumber, bytes32 batchHash, uint64 indexRepeatedStorageChanges, uint256 numberOfLayer1Txs, bytes32 priorityOperationsHash, bytes32 l2LogsTreeRoot, uint256 timestamp, bytes32 commitment)[] batchesData) external",
      ];

      const executor = new Contract(chainAddresses.diamondProxy, executorAbi, this.wallet);

      const batchNumber = state.lastExecuted + 1;

      const batchData: StoredBatchInfo = {
        batchNumber: BigInt(batchNumber),
        batchHash: keccak256(toUtf8Bytes(`batch-${batchNumber}`)),
        indexRepeatedStorageChanges: 0n,
        numberOfLayer1Txs: 0n,
        priorityOperationsHash: keccak256(toUtf8Bytes("empty")),
        l2LogsTreeRoot: keccak256(toUtf8Bytes("logs")),
        timestamp: BigInt(Math.floor(Date.now() / 1000)),
        commitment: keccak256(toUtf8Bytes(`commitment-${batchNumber}`)),
      };

      const tx = await executor.executeBatchesSharedBridge(chainId, [batchData]);

      await tx.wait();

      state.lastExecuted = batchNumber;

      console.log(`✅ Batch ${batchNumber} executed for chain ${chainId}`);
    } catch (error) {
      console.error(`❌ Failed to execute batch for chain ${chainId}:`, error);
    }
  }

  private buildCommitBatchInfo(batchNumber: number, txs: L2Transaction[]): CommitBatchInfo {
    const timestamp = BigInt(Math.floor(Date.now() / 1000));
    const newStateRoot = keccak256(toUtf8Bytes(`state-${batchNumber}-${txs.length}`));
    const systemLogs = this.encodeSystemLogs(txs);

    return {
      batchNumber: BigInt(batchNumber),
      timestamp,
      indexRepeatedStorageChanges: 0n,
      newStateRoot,
      numberOfLayer1Txs: 0n,
      priorityOperationsHash: keccak256(toUtf8Bytes("empty")),
      bootloaderHeapInitialContentsHash: keccak256(toUtf8Bytes("bootloader")),
      eventsQueueStateHash: keccak256(toUtf8Bytes("events")),
      systemLogs,
      operatorDAInput: "0x",
    };
  }

  private encodeSystemLogs(txs: L2Transaction[]): string {
    if (txs.length === 0) {
      return "0x";
    }

    const abiCoder = AbiCoder.defaultAbiCoder();

    const logs = txs.map((tx) => tx.hash);

    return abiCoder.encode(["bytes32[]"], [logs]);
  }

  private generateMockProof(): ProofInput {
    return {
      recursiveAggregationInput: [],
      serializedProof: new Uint8Array(0),
    };
  }
}

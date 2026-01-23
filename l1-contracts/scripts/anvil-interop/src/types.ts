import type { ChildProcess } from "child_process";
import type { JsonRpcProvider } from "ethers";

export interface AnvilChain {
  chainId: number;
  port: number;
  isL1: boolean;
  process?: ChildProcess;
  rpcUrl: string;
}

export interface CoreDeployedAddresses {
  bridgehub: string;
  stateTransitionManager: string;
  validatorTimelock: string;
  l1SharedBridge: string;
  l1NullifierProxy: string;
  l1NativeTokenVault: string;
  l1ERC20Bridge: string;
  governance: string;
  transparentProxyAdmin: string;
  blobVersionedHashRetriever: string;
}

export interface CTMDeployedAddresses {
  chainTypeManager: string;
  chainAdmin: string;
  diamondProxy: string;
  adminFacet: string;
  gettersFacet: string;
  mailboxFacet: string;
  executorFacet: string;
  verifier: string;
  validiumL1DAValidator: string;
  rollupL1DAValidator: string;
}

export interface ChainConfig {
  chainId: number;
  rpcUrl: string;
  baseToken: string;
  validiumMode: boolean;
  isGateway: boolean;
}

export interface ChainAddresses {
  chainId: number;
  diamondProxy: string;
  l2Bridgehub?: string;
  l2AssetRouter?: string;
  l2NativeTokenVault?: string;
}

export interface L2Transaction {
  from: string;
  to: string;
  value: string;
  data: string;
  gasLimit: string;
  maxFeePerGas: string;
  maxPriorityFeePerGas: string;
  nonce: number;
  hash: string;
  blockNumber: number;
}

export interface BatchState {
  chainId: number;
  lastCommitted: number;
  lastProved: number;
  lastExecuted: number;
  pendingTxs: L2Transaction[];
}

export interface CommitBatchInfo {
  batchNumber: bigint;
  timestamp: bigint;
  indexRepeatedStorageChanges: bigint;
  newStateRoot: string;
  numberOfLayer1Txs: bigint;
  priorityOperationsHash: string;
  bootloaderHeapInitialContentsHash: string;
  eventsQueueStateHash: string;
  systemLogs: string;
  operatorDAInput: string;
}

export interface StoredBatchInfo {
  batchNumber: bigint;
  batchHash: string;
  indexRepeatedStorageChanges: bigint;
  numberOfLayer1Txs: bigint;
  priorityOperationsHash: string;
  l2LogsTreeRoot: string;
  timestamp: bigint;
  commitment: string;
}

export interface ProofInput {
  recursiveAggregationInput: number[];
  serializedProof: Uint8Array;
}

export interface AnvilConfig {
  chains: {
    chainId: number;
    port: number;
    isL1: boolean;
    isGateway?: boolean;
  }[];
  batchSettler: {
    pollingIntervalMs: number;
    batchSizeLimit: number;
  };
}

export interface DeploymentContext {
  l1Provider: JsonRpcProvider;
  l2Providers: Map<number, JsonRpcProvider>;
  l1Addresses: CoreDeployedAddresses;
  ctmAddresses: CTMDeployedAddresses;
  chainAddresses: Map<number, ChainAddresses>;
  gatewayChainId?: number;
}

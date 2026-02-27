import type { ChildProcess } from "child_process";

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
  l1AssetTracker: string;
  l1ERC20Bridge: string;
  governance: string;
  transparentProxyAdmin: string;
  blobVersionedHashRetriever: string;
  messageRoot: string;
  ctmDeploymentTracker: string;
  l1ChainAssetHandler: string;
  chainRegistrationSender: string;
}

export interface BalanceSnapshot {
  // Actual token balances
  l1TokenBalance: string;
  l2TokenBalance: string;

  // L1AssetTracker state
  l1ChainBalance: string;

  // GWAssetTracker state (for GW-settled chains)
  gwChainBalance?: string;
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

interface L1ChainInfo {
  chainId: number;
  rpcUrl: string;
  port: number;
}

interface L2ChainInfo {
  chainId: number;
  rpcUrl: string;
  port: number;
}

export interface ChainInfo {
  l1: L1ChainInfo | null;
  l2: L2ChainInfo[];
  config: AnvilConfig["chains"];
}

export interface DeploymentState {
  chains?: ChainInfo;
  l1Addresses?: CoreDeployedAddresses;
  ctmAddresses?: CTMDeployedAddresses;
  chainAddresses?: ChainAddresses[];
  testTokens?: Record<number, string>;
}

export interface MultiChainTokenTransferParams {
  sourceChainId?: number;
  targetChainId?: number;
  amount?: string;
}

export interface FinalizeWithdrawalParams {
  chainId: number;
  l2BatchNumber: number;
  l2MessageIndex: number;
  l2Sender: string;
  l2TxNumberInBatch: number;
  message: string;
  merkleProof: string[];
}

export interface MultiChainTokenTransferResult {
  sourceChainId: number;
  targetChainId: number;
  sourceRpcUrl: string;
  targetRpcUrl: string;
  sender: string;
  sourceToken: string;
  destinationToken: string;
  assetId: string;
  amountWei: string;
  sourceBalanceBefore: string;
  sourceBalanceAfter: string;
  destinationBalanceBefore: string;
  destinationBalanceAfter: string;
  sourceTxHash: string;
  targetTxHash: string | null;
}

export interface PriorityRequestData {
  from: string;
  to: string;
  calldata: string;
  value?: import("ethers").BigNumber;
}

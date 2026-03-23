import type { ChildProcess } from "child_process";
import type { BigNumber } from "ethers";

export interface AnvilChain {
  chainId: number;
  port: number;
  role: ChainRole;
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

  // L1AssetTracker.chainBalance under the chain's own ID
  l1ChainBalance: string;

  // L1AssetTracker.chainBalance under the GW chain ID (for GW-settled chains)
  l1GwChainBalance?: string;

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
}

export interface ChainAddresses {
  chainId: number;
  diamondProxy: string;
}

/** Role of a chain in the test environment. */
export type ChainRole = "l1" | "directSettled" | "gateway" | "gwSettled";

/** Settlement type: where this chain settles. */
export type SettlementType = "l1" | "gateway";

export interface AnvilChainConfig {
  chainId: number;
  port: number;
  role: ChainRole;
  settlement?: SettlementType;
}

export interface AnvilConfig {
  chains: AnvilChainConfig[];
}

interface L1ChainInfo {
  chainId: number;
  rpcUrl: string;
  port: number;
}

export interface L2ChainInfo {
  chainId: number;
  rpcUrl: string;
  port: number;
}

export interface ChainInfo {
  l1: L1ChainInfo | null;
  l2: L2ChainInfo[];
  config: AnvilChainConfig[];
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
  /** Token address on the source chain. If omitted, uses the test token for sourceChainId. */
  sourceTokenAddress?: string;
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
  value?: BigNumber;
}

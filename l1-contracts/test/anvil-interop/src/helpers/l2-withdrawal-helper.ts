import type { BigNumber } from "ethers";
import { Contract, providers, Wallet, ethers } from "ethers";
import { buildWithdrawalMerkleProof, getSettlementLayerChainId } from "../core/utils";
import { getAbi } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ETH_TOKEN_ADDRESS,
  L2_ASSET_ROUTER_ADDR,
  L2_BASE_TOKEN_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  FINALIZE_DEPOSIT_SIG,
} from "../core/const";
import { encodeBridgeBurnData, encodeBridgeMintData, encodeNtvAssetId } from "../core/data-encoding";
import type { CoreDeployedAddresses } from "../core/types";

export interface WithdrawETHParams {
  l1RpcUrl: string;
  l2RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  amount: BigNumber;
  l1Recipient?: string;
}

export interface WithdrawETHResult {
  l2TxHash: string;
  l1TxHash: string | null;
  amount: BigNumber;
}

/**
 * A withdrawal that has been initiated on L2 but not yet finalised on L1.
 *
 * Carries everything needed to either finalise it (when the L1 state allows) or
 * assert that finalisation reverts (when it does not — e.g. before reverse TBM
 * has restored the chain's L1 `chainBalance`).
 */
export interface PendingWithdrawal {
  l2TxHash: string;
  chainId: number;
  assetId: string;
  amount: BigNumber;
  l1Recipient: string;
  tokenAddress: string;
  originalCaller: string;
  /**
   * ERC20 metadata bytes that the L2 NTV injects into the withdrawal message
   * via `_getERC20Metadata` / `getERC20Getters`. Empty for base-token (ETH)
   * withdrawals; required for ERC20 withdrawals so that `L1Nullifier.finalizeDeposit`
   * can call `DataEncoding.decodeTokenData(erc20Metadata)` without reverting
   * with `EmptyData()`.
   */
  erc20Metadata: string;
}

export interface InitiateWithdrawalParams {
  l2RpcUrl: string;
  l1RpcUrl: string;
  chainId: number;
  l1Addresses: CoreDeployedAddresses;
  amount: BigNumber;
  l1Recipient?: string;
}

export interface InitiateErc20WithdrawalParams extends InitiateWithdrawalParams {
  l2TokenAddress: string;
  /**
   * Chain where the token originates. For an L2-native token this is the L2
   * chain id; for an L1-native token bridged to L2 this is `L1_CHAIN_ID`. The
   * value feeds `DataEncoding.encodeNTVAssetId` so the resulting `assetId`
   * matches what the L2 `NativeTokenVault` assigned on registration.
   */
  tokenOriginChainId: number;
}

/**
 * Initiate an ETH withdrawal from L2 to L1 via `L2BaseToken.withdraw()` and
 * return a {@link PendingWithdrawal} handle that can be finalised later.
 */
export async function initiateEthWithdrawal(params: InitiateWithdrawalParams): Promise<PendingWithdrawal> {
  const { l2RpcUrl, l1RpcUrl, chainId, l1Addresses, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Recipient = params.l1Recipient || l2Wallet.address;

  const ntv = new Contract(l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Provider);
  const l1EthAssetId = await ntv.assetId(ETH_TOKEN_ADDRESS);

  const l2BaseToken = new Contract(L2_BASE_TOKEN_ADDR, getAbi("IBaseToken"), l2Wallet);

  console.log(`   Initiating ETH withdrawal from chain ${chainId} via L2BaseToken.withdraw()...`);
  const l2Tx = await l2BaseToken.withdraw(l1Recipient, { value: amount, gasLimit: 5_000_000 });
  await l2Tx.wait();
  console.log(`   L2 withdraw tx: cast run ${l2Tx.hash} -r ${l2RpcUrl}`);

  return {
    l2TxHash: l2Tx.hash,
    chainId,
    assetId: l1EthAssetId,
    amount,
    l1Recipient,
    tokenAddress: ETH_TOKEN_ADDRESS,
    originalCaller: l2Wallet.address,
    erc20Metadata: "0x",
  };
}

/**
 * Initiate an ERC20 withdrawal from L2 to L1 via `L2AssetRouter.withdraw(assetId, data)`.
 *
 * Approves the L2 `NativeTokenVault` to transfer the tokens, then calls
 * `L2AssetRouter.withdraw` which burns on L2 and emits the L2→L1 message that
 * `L1Nullifier.finalizeDeposit` consumes.
 */
export async function initiateErc20Withdrawal(params: InitiateErc20WithdrawalParams): Promise<PendingWithdrawal> {
  const { l2RpcUrl, l2TokenAddress, tokenOriginChainId, chainId, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Recipient = params.l1Recipient || l2Wallet.address;

  // `assetId` is a deterministic function of (origin chain, token address); the
  // L2 NTV assigns the same value during `registerToken`.
  const assetId = encodeNtvAssetId(tokenOriginChainId, l2TokenAddress);

  // Approve the L2 NTV to spend the caller's tokens, then withdraw via the
  // AssetRouter. The `_assetData` format is `abi.encode(amount, l1Receiver, l2TokenAddress)`.
  const erc20 = new Contract(l2TokenAddress, getAbi("TestnetERC20Token"), l2Wallet);
  const approveTx = await erc20.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount, { gasLimit: 500_000 });
  await approveTx.wait();

  const assetData = encodeBridgeBurnData(amount, l1Recipient, l2TokenAddress);
  const l2AssetRouter = new Contract(L2_ASSET_ROUTER_ADDR, getAbi("L2AssetRouter"), l2Wallet);

  // Capture the exact ERC20 metadata bytes that the L2 NTV injects into the
  // withdrawal message via `_getERC20Metadata` / `getERC20Getters`. Reading
  // from the NTV view matches what the on-chain burn will emit, so the
  // reconstructed L1 finalisation message round-trips correctly.
  const l2Ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), l2Provider);
  const erc20Metadata: string = await l2Ntv.getERC20Getters(l2TokenAddress, tokenOriginChainId);

  console.log(`   Initiating ERC20 withdrawal from chain ${chainId} via L2AssetRouter.withdraw()...`);
  const l2Tx = await l2AssetRouter["withdraw(bytes32,bytes)"](assetId, assetData, { gasLimit: 5_000_000 });
  await l2Tx.wait();
  console.log(`   L2 withdraw tx: cast run ${l2Tx.hash} -r ${l2RpcUrl}`);

  return {
    l2TxHash: l2Tx.hash,
    chainId,
    assetId,
    amount,
    l1Recipient,
    tokenAddress: l2TokenAddress,
    originalCaller: l2Wallet.address,
    erc20Metadata,
  };
}

/**
 * Finalise a pending withdrawal on L1 via the real `L1Nullifier.finalizeDeposit`.
 *
 * Returns `{ success: true, txHash }` if the L1 tx lands, otherwise
 * `{ success: false, errorMessage, revertData }` — callers can drive the
 * "attempt → revert → retry" pattern the source TBM suite uses around
 * `InsufficientChainBalance`. When the call reverts, `revertData` carries the
 * 4-byte selector (plus args) so callers can match the exact custom error.
 */
export async function finalizeWithdrawalOnL1(
  l1RpcUrl: string,
  l1Addresses: CoreDeployedAddresses,
  pending: PendingWithdrawal
): Promise<{ success: boolean; txHash?: string; errorMessage?: string; revertData?: string }> {
  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);

  const settlementLayerChainId = await getSettlementLayerChainId(l1Provider, l1Addresses.bridgehub, pending.chainId);

  const isBaseToken = pending.tokenAddress === ETH_TOKEN_ADDRESS;
  let message: string;
  let l2Sender: string;

  if (isBaseToken) {
    const selector = ethers.utils.id("finalizeEthWithdrawal(uint256,uint256,uint16,bytes,bytes32[])").slice(0, 10);
    message = ethers.utils.solidityPack(
      ["bytes4", "address", "uint256"],
      [selector, pending.l1Recipient, pending.amount]
    );
    l2Sender = L2_BASE_TOKEN_ADDR;
  } else {
    const transferData = encodeBridgeMintData(
      pending.originalCaller,
      pending.l1Recipient,
      pending.tokenAddress,
      pending.amount,
      pending.erc20Metadata
    );
    const selector = ethers.utils.id(FINALIZE_DEPOSIT_SIG).slice(0, 10);
    message = ethers.utils.solidityPack(
      ["bytes4", "uint256", "bytes32", "bytes"],
      [selector, pending.chainId, pending.assetId, transferData]
    );
    l2Sender = L2_ASSET_ROUTER_ADDR;
  }

  const merkleProof = buildWithdrawalMerkleProof(settlementLayerChainId);

  const l2BatchNumber = ++finalizationCounter;
  const l1Wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
  const l1Nullifier = new Contract(l1Addresses.l1NullifierProxy, getAbi("L1Nullifier"), l1Wallet);
  const finalizeArgs = [pending.chainId, l2BatchNumber, 0, l2Sender, 0, message, merkleProof];

  console.log(
    `   Finalizing withdrawal on L1 via L1Nullifier (settlement layer: ${settlementLayerChainId || "direct"})...`
  );

  // Simulate via `callStatic` first so we can surface revert data (the exact
  // custom-error selector + args) when the finalisation is expected to fail.
  // Anvil tx receipts strip revert data, so this is the only way to expose it
  // to the caller.
  try {
    await l1Nullifier.callStatic.finalizeDeposit(finalizeArgs, { gasLimit: 5_000_000 });
  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    const revertData = extractRevertDataFromError(error);
    return { success: false, errorMessage, revertData };
  }

  const tx = await l1Nullifier.finalizeDeposit(finalizeArgs, { gasLimit: 5_000_000 });
  const receipt = await tx.wait();
  console.log(`   L1 finalize tx: cast run ${receipt.transactionHash} -r ${l1RpcUrl}`);
  return { success: true, txHash: receipt.transactionHash };
}

function extractRevertDataFromError(err: unknown): string | undefined {
  if (typeof err !== "object" || err === null) return undefined;
  const e = err as { data?: unknown; error?: { data?: unknown } };
  if (typeof e.data === "string") return e.data;
  if (typeof e.error?.data === "string") return e.error.data;
  return undefined;
}

/**
 * Compose {@link initiateEthWithdrawal} + {@link finalizeWithdrawalOnL1} so the
 * common happy-path ETH withdrawal stays a one-call affair.
 */
export async function withdrawETHFromL2(params: WithdrawETHParams): Promise<WithdrawETHResult> {
  const pending = await initiateEthWithdrawal({
    l2RpcUrl: params.l2RpcUrl,
    l1RpcUrl: params.l1RpcUrl,
    chainId: params.chainId,
    l1Addresses: params.l1Addresses,
    amount: params.amount,
    l1Recipient: params.l1Recipient,
  });
  const result = await finalizeWithdrawalOnL1(params.l1RpcUrl, params.l1Addresses, pending);
  return {
    l2TxHash: pending.l2TxHash,
    l1TxHash: result.success && result.txHash ? result.txHash : null,
    amount: params.amount,
  };
}

// Monotonic counter keeping (chainId, l2BatchNumber, l2MessageIndex) unique
// across finalisations within a test session (including retry-after-revert).
// Seeded from wall-clock seconds so repeated `--keep-chains` runs don't clash
// with finalisations from a prior session.
let finalizationCounter = Math.floor(Date.now() / 1000);

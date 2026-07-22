import type { BigNumber } from "ethers";
import { Contract, providers, Wallet, ethers } from "ethers";
import { buildWithdrawalMerkleProof, getSettlementLayerChainId } from "../core/utils";
import { getAbi } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ETH_TOKEN_ADDRESS,
  INTEROP_CENTER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../core/const";
import { encodeAssetRouterBridgehubDepositData, encodeBridgeBurnData, encodeNtvAssetId } from "../core/data-encoding";
import type { CoreDeployedAddresses } from "../core/types";
import { indirectCallAttr, interopCallValueAttr, sendInteropBundle } from "./interop-helpers";
import { encodeEvmAddress } from "./erc7930";

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
 * Carries the exact interop bundle the L2 InteropCenter emitted for this withdrawal (captured from the
 * `InteropBundleSent` event during initiation) plus the metadata needed to assert the finalisation outcome.
 * Reusing that real bundle — rather than reconstructing one — means the L1 finalisation runs on the same
 * bytes the L2 send produced; only the message-inclusion proof is mocked.
 */
export interface PendingWithdrawal {
  l2TxHash: string;
  chainId: number;
  amount: BigNumber;
  l1Recipient: string;
  tokenAddress: string;
  /** ABI-encoded `InteropBundle` emitted by the L2 InteropCenter, reused verbatim for `executeBundle` on L1. */
  bundleData: string;
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
 * Initiate an ETH (base-token) withdrawal from L2 to L1 via the InteropCenter and
 * return a {@link PendingWithdrawal} handle that can be finalised later.
 *
 * Base-token withdrawals use the same unified path as ERC20s: a single-call interop
 * bundle whose indirect call targets the L2 AssetRouter with the base-token assetId,
 * destined for L1. The withdrawn ETH rides as the indirect-call message value, so the
 * AssetRouter/NTV burn it (via BaseTokenHolder) and produce the `finalizeDeposit`
 * message. (The dedicated `L2BaseToken.withdraw` entrypoint was removed.)
 */
export async function initiateEthWithdrawal(params: InitiateWithdrawalParams): Promise<PendingWithdrawal> {
  const { l2RpcUrl, l1RpcUrl, chainId, l1Addresses, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Recipient = params.l1Recipient || l2Wallet.address;

  // The base-token assetId is the ETH NTV assetId (identical on L1 and L2).
  const ntv = new Contract(l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Provider);
  const l1EthAssetId = await ntv.assetId(ETH_TOKEN_ADDRESS);

  // Build the indirect-call bundle targeting the L2 AssetRouter with the base-token
  // assetId. The burn token address is left as `address(0)` so the NTV resolves the
  // base token from the assetId; the withdrawn ETH rides as the indirect-call message
  // value (so `interopCallValue` is zero).
  const transferData = encodeBridgeBurnData(amount, l1Recipient, ethers.constants.AddressZero);
  const depositData = encodeAssetRouterBridgehubDepositData(l1EthAssetId, transferData);
  const callStarter = {
    to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
    data: depositData,
    callAttributes: [indirectCallAttr(amount), interopCallValueAttr(ethers.constants.Zero)],
  };

  const l1ChainId = (await l1Provider.getNetwork()).chainId;

  console.log(
    `   Initiating ETH withdrawal from chain ${chainId} via InteropCenter.sendBundle (destination L1 chain ${l1ChainId})...`
  );
  // L2->L1 withdrawals are free (no interop protocol fee); only the withdrawn ETH rides as value.
  const sendResult = await sendInteropBundle({
    sourceProvider: l2Provider,
    destinationChainId: l1ChainId,
    callStarters: [callStarter],
    value: amount,
    // L2->L1 withdrawal: non-atomic, published to L1 (no atomic flow / bundleHash preview).
    atomic: false,
  });
  console.log(`   L2 withdraw tx: cast run ${sendResult.txHash} -r ${l2RpcUrl}`);

  return {
    l2TxHash: sendResult.txHash,
    chainId,
    amount,
    l1Recipient,
    tokenAddress: ETH_TOKEN_ADDRESS,
    bundleData: sendResult.bundleData,
  };
}

/**
 * Initiate an ERC20 withdrawal from L2 to L1 via the InteropCenter.
 *
 * Approves the L2 `NativeTokenVault` to transfer the tokens, then sends an
 * interop bundle whose single indirect call targets the L2 `AssetRouter` with a
 * destination of the L1 chain. The InteropCenter invokes
 * `L2AssetRouter.initiateIndirectCall`, which builds the bridgehub-deposit
 * request; because the destination is L1, it burns on L2 and produces the
 * single-call interop bundle finalized on L1 via `L1InteropHandler.executeBundle`
 * (which delivers `finalizeDeposit` to the L1 asset router).
 *
 * (The legacy `L2AssetRouter.withdraw(assetId, data)` entrypoint was removed; all
 * L2→L1 withdrawals now flow through the InteropCenter.)
 */
export async function initiateErc20Withdrawal(params: InitiateErc20WithdrawalParams): Promise<PendingWithdrawal> {
  const { l2RpcUrl, l1RpcUrl, l2TokenAddress, tokenOriginChainId, chainId, amount } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  const l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Recipient = params.l1Recipient || l2Wallet.address;

  // `assetId` is a deterministic function of (origin chain, token address); the
  // L2 NTV assigns the same value during `registerToken`.
  const assetId = encodeNtvAssetId(tokenOriginChainId, l2TokenAddress);

  // Approve the L2 NTV to spend the caller's tokens. The InteropCenter routes
  // the burn through `L2AssetRouter.initiateIndirectCall` -> `_bridgehubDeposit`,
  // which pulls the tokens from the original caller (the `sendBundle` sender)
  // via the NTV.
  const erc20 = new Contract(l2TokenAddress, getAbi("TestnetERC20Token"), l2Wallet);
  const approveTx = await erc20.approve(L2_NATIVE_TOKEN_VAULT_ADDR, amount, { gasLimit: 500_000 });
  await approveTx.wait();

  // Build the indirect-call bundle targeting the L2 AssetRouter. The burn data
  // is `abi.encode(amount, l1Receiver, l2TokenAddress)`, wrapped as the
  // bridgehub-deposit payload the AssetRouter expects.
  const transferData = encodeBridgeBurnData(amount, l1Recipient, l2TokenAddress);
  const depositData = encodeAssetRouterBridgehubDepositData(assetId, transferData);
  const callStarter = {
    to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
    data: depositData,
    callAttributes: [indirectCallAttr(), interopCallValueAttr(ethers.constants.Zero)],
  };

  // Destination is the L1 chain: `L2AssetRouter.initiateIndirectCall` targets the
  // L1 AssetRouter's `finalizeDeposit` when the destination chain is L1.
  const l1ChainId = (await l1Provider.getNetwork()).chainId;

  console.log(
    `   Initiating ERC20 withdrawal from chain ${chainId} via InteropCenter.sendBundle (destination L1 chain ${l1ChainId})...`
  );
  // L2->L1 withdrawals are free (no interop protocol fee), so no value rides along.
  const sendResult = await sendInteropBundle({
    sourceProvider: l2Provider,
    destinationChainId: l1ChainId,
    callStarters: [callStarter],
    value: ethers.constants.Zero,
    // L2->L1 withdrawal: non-atomic, published to L1 (no atomic flow / bundleHash preview).
    atomic: false,
  });
  console.log(`   L2 withdraw tx: cast run ${sendResult.txHash} -r ${l2RpcUrl}`);

  return {
    l2TxHash: sendResult.txHash,
    chainId,
    amount,
    l1Recipient,
    tokenAddress: l2TokenAddress,
    bundleData: sendResult.bundleData,
  };
}

/**
 * Finalise a pending withdrawal on L1 via the real `L1InteropHandler.executeBundle`
 * (the nullifier points to the handler, which re-invokes the L1 asset router's `finalizeDeposit`).
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

  const l1Wallet = new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
  // Withdrawal finalization runs through the L1 interop handler's generic `executeBundle` (symmetric to the
  // L2 InteropHandler), which the nullifier points to.
  const l1Nullifier = new Contract(l1Addresses.l1NullifierProxy, getAbi("L1Nullifier"), l1Provider);
  const interopHandlerAddress = await l1Nullifier.l1InteropHandler();
  const l1InteropHandler = new Contract(interopHandlerAddress, getAbi("L1InteropHandler"), l1Wallet);

  // Reuse the exact bundle the L2 InteropCenter emitted for this withdrawal (captured from the
  // `InteropBundleSent` event during initiation). It already carries the correct source/destination chain ids,
  // the L1 ETH destination base-token assetId, the InteropCenter-assigned salt (so distinct withdrawals never
  // collide into the same bundle hash), and the single call targeting the L1 asset router's `finalizeDeposit`.
  // Only the message-inclusion proof below is mocked.
  const bundle = pending.bundleData;

  const l2BatchNumber = ++finalizationCounter;
  const l2Sender = INTEROP_CENTER_ADDR;

  const merkleProof = buildWithdrawalMerkleProof(settlementLayerChainId);
  // MessageInclusionProof: the handler substitutes `message.data` with the bundle while proving inclusion, so the
  // data field is a placeholder here. The batch number only needs to be unique per finalization under the mock.
  const proof = [pending.chainId, l2BatchNumber, 0, [0, l2Sender, "0x"], merkleProof];

  console.log(
    `   Finalizing withdrawal on L1 via L1InteropHandler.executeBundle (settlement layer: ${settlementLayerChainId || "direct"})...`
  );

  // Simulate via `callStatic` first so we can surface revert data (the exact
  // custom-error selector + args) when the finalisation is expected to fail.
  // Anvil tx receipts strip revert data, so this is the only way to expose it
  // to the caller.
  try {
    await l1InteropHandler.callStatic.executeBundle(bundle, proof, { gasLimit: 5_000_000 });
  } catch (error: unknown) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    const revertData = extractRevertDataFromError(error);
    return { success: false, errorMessage, revertData };
  }

  const tx = await l1InteropHandler.executeBundle(bundle, proof, { gasLimit: 5_000_000 });
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

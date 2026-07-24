/**
 * Interop bundle and message helpers.
 *
 * Provides RPC wrappers for InteropCenter.sendBundle / sendMessage and
 * InteropHandler.executeBundle / verifyBundle / unbundleBundle, along with
 * ERC-7786 attribute encoding and contract deployment utilities.
 */

import { expect } from "chai";
import type { providers, BigNumber } from "ethers";
import { Contract, ethers, Wallet } from "ethers";
import { getAbi, getCreationBytecode } from "../core/contracts";
import { getInteropSourcePrivateKey, isLiveInteropMode } from "../core/accounts";
import {
  ATOMIC_SEND_BUNDLE_GAS_LIMIT,
  DEFAULT_TX_GAS_LIMIT,
  INTEROP_BUNDLE_TUPLE_TYPE,
  INTEROP_CENTER_ADDR,
  L2_BOOTLOADER_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_INTEROP_COMMITMENT_TREE_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../core/const";
import { encodeBridgeBurnData, encodeAssetRouterBridgehubDepositData } from "../core/data-encoding";
import { impersonateAndRun } from "../core/utils";
import { encodeEvmChain, encodeEvmAddress } from "./erc7930";
import {
  atomicFinalityProofTuple,
  buildInclusionProof,
  commitValue,
  commitmentTree,
  computeFlowId,
  flowPreimageTuple,
  lowNullifierIndexFor,
  DEFAULT_SL_CHAIN_ID,
} from "./imt-engine-lib";
import type { AtomicFlowPreimage } from "./imt-engine-lib";
export type { AtomicFlowPreimage } from "./imt-engine-lib";
import { approveTokenForNtv, expectBalanceDelta, getTokenAddressForAsset, getTokenBalance } from "./balance-helpers";

const abiCoder = ethers.utils.defaultAbiCoder;
const sendResultsByBundleData = new Map<string, InteropSendResult>();

/**
 * Far-future settlement-layer deadline used for the single-leg atomic flows these helpers build. The
 * anvil harness mocks root-message authentication and fabricates each proof's `l1Timestamp` (see
 * imt-engine-lib), so the only real check is `l1Timestamp <= deadline`; a large fixed deadline satisfies
 * it without any wall-clock coupling. Kept identical between the send (attribute) and the execute
 * (finality proof) so the derived `flowId` matches.
 */
const ATOMIC_INTEROP_DEADLINE = 4_000_000_000;

/**
 * Derives the single-leg atomic-flow metadata for a predicted `bundleHash`: computes the `flowId` (which
 * commits to the hash), finds the IMT low-nullifier index for the commit value, and returns the
 * `atomicBundle` attribute to attach to the send plus the flow fields needed later to build the
 * {AtomicFinalityProof} at execute time.
 */
async function buildSingleLegAtomicSend(
  sourceProvider: providers.JsonRpcProvider,
  bundleHash: string
): Promise<{ attribute: string; flowId: string; preimage: AtomicFlowPreimage; sourceChainId: number }> {
  const sourceChainId = (await sourceProvider.getNetwork()).chainId;
  // Single-leg flow preimage: this bundle is the only leg, sourced from this chain. `flowId` is
  // recomputed on-chain from this exact preimage, so it must match byte-for-byte at execute time.
  const preimage: AtomicFlowPreimage = {
    deadline: ATOMIC_INTEROP_DEADLINE,
    settlementLayerChainId: DEFAULT_SL_CHAIN_ID,
    legBundleHashes: [bundleHash],
    legSourceChainIds: [sourceChainId],
  };
  const flowId = computeFlowId(preimage);
  const value = commitValue(flowId, bundleHash);
  const tree = commitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR, sourceProvider);
  const lowNull = await lowNullifierIndexFor(tree, value);
  return { attribute: atomicBundleAttr(preimage, lowNull), flowId, preimage, sourceChainId };
}

/**
 * Builds the single-leg {AtomicFinalityProof} tuple for a previously-sent bundle, proving its commit leaf
 * is present in the source chain's {L2InteropCommitmentTree}. Root-message authentication is mocked to
 * `true` on the anvil harness, so the exercised checks are IMT membership and `l1Timestamp <= deadline`.
 */
async function buildSingleLegFinality(sendResult: InteropSendResult): Promise<unknown> {
  const value = commitValue(sendResult.flowId, sendResult.bundleHash);
  const tree = commitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR, sendResult.sourceProvider);
  const proof = await buildInclusionProof({
    l2Tree: tree,
    chainId: sendResult.legSourceChainId,
    value,
    l1Timestamp: sendResult.preimage.deadline,
  });
  return atomicFinalityProofTuple({
    flowId: sendResult.flowId,
    preimage: sendResult.preimage,
    proofs: [proof],
  });
}

/** IERC7786Attributes interface — used for attribute encoding via encodeFunctionData. */
const erc7786Iface = new ethers.utils.Interface(getAbi("IERC7786Attributes"));

export interface AccumulatedProtocolFeesSnapshot {
  coinbase: string;
  amount: BigNumber;
}

// ── ERC-7786 attribute encoding ────────────────────────────────
// Uses IERC7786Attributes.encodeFunctionData so selectors and parameter
// encoding are derived from the Solidity interface — no manual hex.

/** Encode an interopCallValue attribute (direct call: transfers base token value). */
export function interopCallValueAttr(amount: BigNumber): string {
  return erc7786Iface.encodeFunctionData("interopCallValue", [amount]);
}

/** Encode an indirectCall attribute (indirect call: routes through asset router). */
export function indirectCallAttr(callValue?: BigNumber): string {
  return erc7786Iface.encodeFunctionData("indirectCall", [callValue || 0]);
}

/** Encode an executionAddress bundle attribute. */
export function executionAddressAttr(address: string): string {
  return erc7786Iface.encodeFunctionData("executionAddress", [encodeEvmAddress(address)]);
}

/** Encode an unbundlerAddress bundle attribute. */
export function unbundlerAddressAttr(address: string): string {
  return erc7786Iface.encodeFunctionData("unbundlerAddress", [encodeEvmAddress(address)]);
}

/** Encode a useFixedFee bundle attribute. */
export function useFixedFeeAttr(useFixedFee: boolean): string {
  return erc7786Iface.encodeFunctionData("useFixedFee", [useFixedFee]);
}

/**
 * Encode the ERC-7786 `atomicBundle(AtomicFlowPreimage flowPreimage, uint256 lowNullifierIndex)`
 * bundle attribute. All L2->L2 interop is atomic (public L1 publication was removed).
 * See {protocol-docs/atomicity/README.md#key-values}.
 */
export function atomicBundleAttr(flowPreimage: AtomicFlowPreimage, lowNullifierIndex: number): string {
  return erc7786Iface.encodeFunctionData("atomicBundle", [flowPreimageTuple(flowPreimage), lowNullifierIndex]);
}

/** Encode an interopBundleSalt bundle attribute. */
export function interopBundleSaltAttr(salt: string): string {
  return erc7786Iface.encodeFunctionData("interopBundleSalt", [salt]);
}

/** Selector of the mandatory `atomicBundle` bundle attribute. */
const ATOMIC_BUNDLE_SELECTOR = erc7786Iface.getSighash("atomicBundle").toLowerCase();

/**
 * True if `attrs` already carries an `atomicBundle` attribute. When it does, the caller manages the atomic
 * flow itself (e.g. a multi-leg swap that shares one `flowId` across legs — see 13-imt-atomic-swap), so the
 * send helpers must NOT derive and attach their own single-leg flow.
 */
function hasAtomicBundleAttribute(attrs: string[]): boolean {
  return attrs.some((a) => a.slice(0, 10).toLowerCase() === ATOMIC_BUNDLE_SELECTOR);
}

/** Decode `(flowId, preimage)` from a caller-provided `atomicBundle` attribute (which carries the full
 * `AtomicFlowPreimage`; `flowId` is recomputed from it, matching the on-chain derivation). */
function decodeAtomicBundleAttribute(attrs: string[]): { flowId: string; preimage: AtomicFlowPreimage } {
  const attr = attrs.find((a) => a.slice(0, 10).toLowerCase() === ATOMIC_BUNDLE_SELECTOR);
  if (!attr) {
    throw new Error("atomicBundle attribute not present");
  }
  const decoded = erc7786Iface.decodeFunctionData("atomicBundle", attr);
  const raw = decoded[0];
  const preimage: AtomicFlowPreimage = {
    deadline: Number(raw[0]),
    settlementLayerChainId: raw[1],
    legBundleHashes: raw[2] as string[],
    legSourceChainIds: raw[3] as BigNumber[],
  };
  return { flowId: computeFlowId(preimage), preimage };
}

/** Selector of the interopBundleSalt bundle attribute, used to detect whether a salt was already supplied. */
const INTEROP_BUNDLE_SALT_SELECTOR = erc7786Iface.getSighash("interopBundleSalt");

/**
 * Attach a fresh `interopBundleSalt` attribute when the caller did not supply one, so every harness
 * bundle gets a unique (sender, salt) pair. The salt is derived from `(sender, account nonce)`, not
 * random bytes: re-runs reproduce identical salts, keeping the pre-generated chain-state snapshots
 * byte-deterministic, while runs against a loaded snapshot cannot collide with salts already used
 * during state generation (the account nonce has advanced).
 */
async function ensureUniqueBundleSalt(attributes: string[], wallet: Wallet): Promise<string[]> {
  const hasSalt = attributes.some((attr) => attr.slice(0, 10).toLowerCase() === INTEROP_BUNDLE_SALT_SELECTOR);
  if (hasSalt) {
    return attributes;
  }
  const nonce = await wallet.getTransactionCount();
  const salt = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(["address", "uint256"], [wallet.address, nonce])
  );
  return [...attributes, interopBundleSaltAttr(salt)];
}

/**
 * Pull the ABI-encoded revert data (`0x<selector><args>`) out of an ethers v5 `eth_call` rejection.
 * Different providers nest it differently, so probe the common shapes.
 */
function extractRevertData(_err: unknown): string | undefined {
  const err = _err as { error?: { data?: unknown }; data?: unknown; body?: string };
  const candidates: unknown[] = [err?.error && (err.error as { data?: unknown }).data, err?.data];
  if (typeof err?.body === "string") {
    try {
      candidates.push((JSON.parse(err.body) as { error?: { data?: unknown } })?.error?.data);
    } catch {
      // body was not JSON
    }
  }
  for (const c of candidates) {
    if (typeof c === "string" && c.startsWith("0x") && c.length >= 10) return c;
    if (c && typeof c === "object") {
      const nested = (c as { data?: unknown }).data;
      if (typeof nested === "string" && nested.startsWith("0x") && nested.length >= 10) return nested;
    }
  }
  return undefined;
}

/**
 * Statically evaluate `previewBundleHash` / `previewMessageHash` (the two functions that predict a bundle's
 * hash before the real send) and return the predicted bundle hash.
 *
 * Both preview functions follow the quoter pattern: they run the identical bundle assembly as the real send
 * (including, for an INDIRECT leg, the value-burning `L2AssetRouter.initiateIndirectCall{value: ...}`) and
 * then ALWAYS revert with `InteropPreviewHash(bundleHash)` rather than returning it — so the burn can never
 * be committed on-chain regardless of caller/context. We therefore invoke them via `eth_call` (expecting the
 * revert) and decode the hash out of the `InteropPreviewHash` reason.
 *
 * Two `eth_call` details make the assembly faithful:
 *  - The InteropCenter's balance is overridden to a large value so it can fund the forwarded
 *    `indirectCallMessageValue` of a cross-base-token indirect leg (msg.value is not forwarded to a preview);
 *    the forwarded amount is fixed by the call, so the predicted hash is identical to the real send's.
 *  - `_from` MUST be the address that will submit the real send: the preview derives the bundle salt and each
 *    call's `from` from `msg.sender`, so a mismatch would predict a different hash.
 * The state override and the reverted assembly are both discarded with the call; nothing persists.
 */
// ~3.4e38 wei — far larger than any interop value leg, so the InteropCenter can always fund the
// forwarded `indirectCallMessageValue` during the read-only preview.
const PREVIEW_INTEROP_CENTER_BALANCE_OVERRIDE = "0xffffffffffffffffffffffffffffffff";
export async function staticPreviewHash(
  _interopCenter: Contract,
  _provider: providers.JsonRpcProvider,
  _from: string,
  _fnName: "previewBundleHash" | "previewMessageHash",
  _args: unknown[]
): Promise<string> {
  const data = _interopCenter.interface.encodeFunctionData(_fnName, _args);
  let revertData: string | undefined;
  try {
    await _provider.send("eth_call", [
      { to: INTEROP_CENTER_ADDR, from: _from, data },
      "latest",
      { [INTEROP_CENTER_ADDR]: { balance: PREVIEW_INTEROP_CENTER_BALANCE_OVERRIDE } },
    ]);
    throw new Error(`${_fnName} was expected to revert with InteropPreviewHash (quoter pattern) but returned`);
  } catch (e) {
    revertData = extractRevertData(e);
    if (!revertData) throw e;
  }
  // The revert reason is `InteropPreviewHash(bytes32 bundleHash)`; decode via the imported InteropCenter ABI.
  return _interopCenter.interface.decodeErrorResult("InteropPreviewHash", revertData)[0] as string;
}

// ── Token transfer data encoding ───────────────────────────────

/**
 * Encode the secondBridgeData for an ERC20 token transfer via L2AssetRouter.
 * This is the `data` field of an indirect call starter targeting L2_ASSET_ROUTER_ADDR.
 */
export function getTokenTransferData(assetId: string, amount: BigNumber, recipientAddress: string): string {
  const transferData = encodeBridgeBurnData(amount, recipientAddress, ethers.constants.AddressZero);
  return encodeAssetRouterBridgehubDepositData(assetId, transferData);
}

export interface SendAndExecuteTokenInteropParams {
  sendProvider: providers.JsonRpcProvider;
  receiveProvider: providers.JsonRpcProvider;
  sourceChainId: number;
  destinationChainId: number;
  sourceTokenAddress: string;
  assetId: string;
  amount: BigNumber;
  recipientAddress: string;
  label: string;
}

export async function sendAndExecuteTokenInterop(params: SendAndExecuteTokenInteropParams): Promise<string> {
  await approveTokenForNtv(params.sendProvider, params.sourceTokenAddress, params.amount);
  // Interop eligibility only requires NTV registration; a token bridged in from another chain is
  // already registered during its bridgeMint, so this is a no-op for those.
  await registerL2NativeTokenIfNeeded(params.sendProvider, params.sourceTokenAddress);
  const fee = await getInteropProtocolFee(params.sendProvider);

  const destTokenBefore = await getTokenAddressForAsset(params.receiveProvider, params.assetId);
  const recipientBefore = await getTokenBalance(params.receiveProvider, destTokenBefore, params.recipientAddress);

  const sendResult = await sendInteropBundle({
    sourceProvider: params.sendProvider,
    destinationChainId: params.destinationChainId,
    callStarters: [
      {
        to: encodeEvmAddress(L2_ASSET_ROUTER_ADDR),
        data: getTokenTransferData(params.assetId, params.amount, params.recipientAddress),
        callAttributes: [indirectCallAttr()],
      },
    ],
    value: fee,
  });

  expect(sendResult.txHash, `${params.label}: tx hash should exist`).to.not.be.null;
  const receipt = await executeBundle(params.receiveProvider, sendResult, params.sourceChainId);
  expect(receipt.status, `${params.label}: executeBundle tx should succeed`).to.equal(1);

  const destTokenAfter = await getTokenAddressForAsset(params.receiveProvider, params.assetId);
  const recipientAfter = await getTokenBalance(params.receiveProvider, destTokenAfter, params.recipientAddress);
  expectBalanceDelta(recipientBefore, recipientAfter, params.amount, `${params.label}: recipient token`);
  return destTokenAfter;
}

/** Registers a chain-native token in the L2NativeTokenVault if it is not already registered. */
export async function registerL2NativeTokenIfNeeded(
  provider: providers.JsonRpcProvider,
  tokenAddress: string
): Promise<void> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), provider);
  const ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), wallet);
  const registeredAssetId: string = await ntv.assetId(tokenAddress);
  if (registeredAssetId === ethers.constants.HashZero) {
    const tx = await ntv.registerToken(tokenAddress, { gasLimit: 500_000 });
    await tx.wait();
  }
}

// ── InteropCenter.sendBundle wrapper ───────────────────────────

export interface CallStarter {
  to: string; // ERC-7930 encoded destination address
  data: string; // calldata
  callAttributes: string[]; // ERC-7786 per-call attributes
}

export interface SendBundleOptions {
  sourceProvider: providers.JsonRpcProvider;
  destinationChainId: number;
  callStarters: CallStarter[];
  bundleAttributes?: string[];
  value?: BigNumber;
  gasLimit?: number;
  /**
   * Set to `false` for an L2->L1 withdrawal: the bundle is published to L1 and finalized there via a
   * message-inclusion proof, so there is no atomic flow to predict — skip the `previewBundleHash` /
   * `atomicBundle` attribute path (which is L2<->L2 only). Defaults to atomic (L2<->L2).
   */
  atomic?: boolean;
}

export interface InteropSendResult {
  txHash: string;
  sourceTxHash: string;
  sourceProvider: providers.JsonRpcProvider;
  proofIndex: number;
  receipt: ethers.providers.TransactionReceipt;
  /** Raw decoded InteropBundle struct from the InteropBundleSent event (ethers tuple). */
  interopBundle: unknown;
  /** ABI-encoded bundle data, ready for executeBundle / verifyBundle / unbundleBundle. */
  bundleData: string;
  bundleHash: string;
  /** Atomic-flow id this bundle was committed under (single-leg flow: `[bundleHash]`). */
  flowId: string;
  /** The full flow preimage this bundle committed under; used to rebuild the AtomicFinalityProof at
   * execute time so the on-chain `flowId` recomputation matches. Empty legs for a non-atomic withdrawal. */
  preimage: AtomicFlowPreimage;
  /** Source chain id of the (single) leg — used to build the AtomicFinalityProof at execute time. */
  legSourceChainId: number;
}

/**
 * Send an interop bundle via InteropCenter.sendBundle on the source chain.
 * Returns the tx receipt and the extracted InteropBundle struct.
 */
export async function sendInteropBundle(options: SendBundleOptions): Promise<InteropSendResult> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), options.sourceProvider);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);

  const destinationChainIdBytes = encodeEvmChain(options.destinationChainId);
  // Attributes carry a stable salt used for BOTH the hash prediction and the real send.
  const baseAttributes = await ensureUniqueBundleSalt(options.bundleAttributes || [], wallet);

  // Interop is atomic. Two cases:
  //  - caller-managed (a multi-leg swap already supplied its shared `atomicBundle` attribute): send the
  //    attributes as-is; the caller owns the flow and builds its own AtomicFinalityProof at execute time.
  //  - single-leg (the common case): predict the bundleHash the send will emit — via a static preview that
  //    runs the real assembly, including the burning indirect-call, but persists nothing — then derive the
  //    single-leg atomic flow that commits to it and attach the `atomicBundle` attribute.
  let attributes: string[];
  let flowId: string;
  let preimage: AtomicFlowPreimage;
  let legSourceChainId: number;
  let predictedBundleHash: string | undefined;
  // Empty preimage for the non-atomic withdrawal path (unused on the L1 finalization path).
  const emptyPreimage: AtomicFlowPreimage = {
    deadline: 0,
    settlementLayerChainId: 0,
    legBundleHashes: [],
    legSourceChainIds: [],
  };
  if (options.atomic === false) {
    // L2->L1 withdrawal: non-atomic. The bundle is published to L1 and finalized there via a
    // message-inclusion proof, so there is no atomic flow to predict — send the attributes as-is and
    // leave the atomic flow fields empty (they are unused on the withdrawal finalization path).
    attributes = baseAttributes;
    flowId = ethers.constants.HashZero;
    preimage = emptyPreimage;
    legSourceChainId = (await options.sourceProvider.getNetwork()).chainId;
  } else if (hasAtomicBundleAttribute(baseAttributes)) {
    attributes = baseAttributes;
    ({ flowId, preimage } = decodeAtomicBundleAttribute(baseAttributes));
    legSourceChainId = (await options.sourceProvider.getNetwork()).chainId;
  } else {
    const predicted: string = await staticPreviewHash(
      interopCenter,
      options.sourceProvider,
      wallet.address,
      "previewBundleHash",
      [destinationChainIdBytes, options.callStarters, baseAttributes]
    );
    predictedBundleHash = predicted;
    const atomic = await buildSingleLegAtomicSend(options.sourceProvider, predicted);
    attributes = [...baseAttributes, atomic.attribute];
    flowId = atomic.flowId;
    preimage = atomic.preimage;
    legSourceChainId = atomic.sourceChainId;
  }

  const tx = await interopCenter.sendBundle(destinationChainIdBytes, options.callStarters, attributes, {
    // Atomic sends append to the IMT (~1.1M-gas insert) on top of the calls; needs the larger cap.
    gasLimit: options.gasLimit || ATOMIC_SEND_BUNDLE_GAS_LIMIT,
    value: options.value || 0,
  });
  const receipt = await tx.wait();

  // Extract InteropBundleSent event
  let interopBundle: unknown = null;
  let bundleHash: string = ethers.constants.HashZero;
  for (const logEntry of receipt.logs) {
    try {
      const parsed = interopCenter.interface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsed?.name === "InteropBundleSent") {
        interopBundle = parsed.args["interopBundle"];
        bundleHash = parsed.args["interopBundleHash"];
        break;
      }
    } catch {
      // Not an InteropCenter log
    }
  }
  if (!interopBundle) {
    throw new Error("InteropBundleSent event not found in source transaction receipt");
  }

  // For the auto single-leg path the predicted hash feeds the atomic flowId; a mismatch would make the
  // finality proof unverifiable. (Caller-managed flows do their own cross-check.)
  if (predictedBundleHash !== undefined && bundleHash.toLowerCase() !== predictedBundleHash.toLowerCase()) {
    throw new Error(`predicted bundleHash ${predictedBundleHash} != emitted ${bundleHash}`);
  }

  const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);

  const result = {
    txHash: tx.hash,
    sourceTxHash: tx.hash,
    sourceProvider: options.sourceProvider,
    proofIndex: 0,
    receipt,
    interopBundle,
    bundleData,
    bundleHash,
    flowId,
    preimage,
    legSourceChainId,
  };
  sendResultsByBundleData.set(bundleData, result);
  return result;
}

/**
 * Simulate InteropCenter.sendBundle via callStatic to capture revert data without sending a tx.
 */
export async function simulateInteropBundle(options: SendBundleOptions): Promise<void> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), options.sourceProvider);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);

  const destinationChainIdBytes = encodeEvmChain(options.destinationChainId);
  const baseAttributes = await ensureUniqueBundleSalt(options.bundleAttributes || [], wallet);
  // Mirror `sendInteropBundle`'s attribute construction so the callStatic exercises the full path (value
  // collection included — the preview alone skips it, so reverts like MsgValueMismatch only surface on the
  // real `sendBundle`). An L2->L1 withdrawal (`atomic === false`) is non-atomic: it carries no `atomicBundle`
  // attribute, and `previewBundleHash` (which enforces `_ensureL2ToL2`) must NOT be called for an L1 dest.
  let attributes: string[];
  if (options.atomic === false) {
    attributes = baseAttributes;
  } else {
    const predictedBundleHash: string = await staticPreviewHash(
      interopCenter,
      options.sourceProvider,
      wallet.address,
      "previewBundleHash",
      [destinationChainIdBytes, options.callStarters, baseAttributes]
    );
    const atomic = await buildSingleLegAtomicSend(options.sourceProvider, predictedBundleHash);
    attributes = [...baseAttributes, atomic.attribute];
  }
  await interopCenter.callStatic.sendBundle(destinationChainIdBytes, options.callStarters, attributes, {
    gasLimit: options.gasLimit || ATOMIC_SEND_BUNDLE_GAS_LIMIT,
    value: options.value || 0,
  });
}

// ── InteropCenter.sendMessage wrapper ──────────────────────────

export interface SendMessageOptions {
  sourceProvider: providers.JsonRpcProvider;
  recipient: string; // ERC-7930 encoded recipient
  payload: string;
  attributes: string[];
  value?: BigNumber;
  gasLimit?: number;
}

/**
 * Send a single interop message via InteropCenter.sendMessage on the source chain.
 * Returns the tx receipt and the extracted InteropBundle struct (sendMessage wraps into a bundle).
 */
export async function sendInteropMessage(options: SendMessageOptions): Promise<InteropSendResult> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), options.sourceProvider);
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);

  const baseAttributes = await ensureUniqueBundleSalt(options.attributes, wallet);
  // Single-call sends are single-leg atomic flows too: predict the bundleHash (of the wrapping bundle)
  // and attach the atomic flow that commits to it.
  const predictedBundleHash: string = await staticPreviewHash(
    interopCenter,
    options.sourceProvider,
    wallet.address,
    "previewMessageHash",
    [options.recipient, options.payload, baseAttributes]
  );
  const atomic = await buildSingleLegAtomicSend(options.sourceProvider, predictedBundleHash);

  const tx = await interopCenter.sendMessage(
    options.recipient,
    options.payload,
    [...baseAttributes, atomic.attribute],
    {
      gasLimit: options.gasLimit || ATOMIC_SEND_BUNDLE_GAS_LIMIT,
      value: options.value || 0,
    }
  );
  const receipt = await tx.wait();

  // Extract InteropBundleSent event
  let interopBundle: unknown = null;
  let bundleHash: string = ethers.constants.HashZero;
  for (const logEntry of receipt.logs) {
    try {
      const parsed = interopCenter.interface.parseLog({ topics: logEntry.topics, data: logEntry.data });
      if (parsed?.name === "InteropBundleSent") {
        interopBundle = parsed.args["interopBundle"];
        bundleHash = parsed.args["interopBundleHash"];
        break;
      }
    } catch {
      // Not an InteropCenter log
    }
  }
  if (!interopBundle) {
    throw new Error("InteropBundleSent event not found in sendMessage receipt");
  }

  if (bundleHash.toLowerCase() !== predictedBundleHash.toLowerCase()) {
    throw new Error(`predicted message bundleHash ${predictedBundleHash} != emitted ${bundleHash}`);
  }

  const bundleData = abiCoder.encode([INTEROP_BUNDLE_TUPLE_TYPE], [interopBundle]);

  const result = {
    txHash: tx.hash,
    sourceTxHash: tx.hash,
    sourceProvider: options.sourceProvider,
    proofIndex: 0,
    receipt,
    interopBundle,
    bundleData,
    bundleHash,
    flowId: atomic.flowId,
    preimage: atomic.preimage,
    legSourceChainId: atomic.sourceChainId,
  };
  sendResultsByBundleData.set(bundleData, result);
  return result;
}

// ── InteropHandler.executeBundle wrapper ───────────────────────

export type BundleExecutionInput = string | InteropSendResult;

export interface InteropExecutionData {
  bundleData: string;
  proof: unknown;
}

export async function getInteropExecutionData(
  _destProvider: providers.JsonRpcProvider,
  bundleInput: BundleExecutionInput,
  _sourceChainId: number
): Promise<InteropExecutionData> {
  // Atomic interop: the proof is a per-leg IMT inclusion proof ({AtomicFinalityProof}) built from the
  // source chain's commitment tree, not a live gateway message-inclusion proof. The flow metadata
  // (flowId/deadline/source chain) was recorded when the bundle was sent. `_destProvider` and
  // `_sourceChainId` are therefore unused here; they are kept for signature parity with `executeBundle`.
  void _destProvider;
  void _sourceChainId;
  const sendResult = getSendResult(bundleInput);
  if (isLiveInteropMode()) {
    throw new Error("Atomic live-mode interop proof generation is not yet implemented");
  }
  const proof = await buildSingleLegFinality(sendResult);
  return {
    bundleData: sendResult.bundleData,
    proof,
  };
}

/**
 * Execute an interop bundle on the destination chain via InteropHandler.executeBundle.
 * Builds the atomic {AtomicFinalityProof} (single-leg IMT inclusion) from the source chain's commitment
 * tree; the bundle must have been sent via `sendInteropBundle`/`sendInteropMessage` in this process.
 */
export async function executeBundle(
  destProvider: providers.JsonRpcProvider,
  bundleInput: BundleExecutionInput,
  sourceChainId: number,
  gasLimit?: number
): Promise<ethers.providers.TransactionReceipt> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), wallet);
  const { bundleData, proof } = await getInteropExecutionData(destProvider, bundleInput, sourceChainId);

  const tx = await interopHandler.executeAtomicBundle(bundleData, proof, {
    gasLimit: gasLimit || DEFAULT_TX_GAS_LIMIT,
  });
  return tx.wait();
}

/**
 * Simulate InteropHandler.executeBundle via callStatic to capture revert data without sending a tx.
 */
export async function simulateExecuteBundle(
  destProvider: providers.JsonRpcProvider,
  bundleInput: BundleExecutionInput,
  sourceChainId: number,
  gasLimit?: number
): Promise<void> {
  const wallet = new Wallet(getInteropSourcePrivateKey(), destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), wallet);
  const { bundleData, proof } = await getInteropExecutionData(destProvider, bundleInput, sourceChainId);

  await interopHandler.callStatic.executeAtomicBundle(bundleData, proof, {
    gasLimit: gasLimit || DEFAULT_TX_GAS_LIMIT,
  });
}

/**
 * Verify a bundle on the destination chain via InteropHandler.verifyBundle.
 * Uses the same atomic {AtomicFinalityProof} as {executeBundle}; marks the bundle Verified so it can
 * later be unbundled.
 */
export async function verifyBundle(
  destProvider: providers.JsonRpcProvider,
  bundleInput: BundleExecutionInput,
  sourceChainId: number,
  signerKey?: string
): Promise<ethers.providers.TransactionReceipt> {
  const wallet = new Wallet(signerKey || getInteropSourcePrivateKey(), destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), wallet);
  const { bundleData, proof } = await getInteropExecutionData(destProvider, bundleInput, sourceChainId);

  const tx = await interopHandler.verifyAtomicBundle(bundleData, proof, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  return tx.wait();
}

/**
 * Resolves the {InteropSendResult} for a bundle. Atomic execution needs the flow metadata
 * (flowId/deadline/source chain) recorded at send time, so a bare `bundleData` string is only usable if
 * its bundle was sent via `sendInteropBundle`/`sendInteropMessage` in this process.
 */
function getSendResult(bundleInput: BundleExecutionInput): InteropSendResult {
  if (typeof bundleInput !== "string") {
    return bundleInput;
  }
  const sendResult = sendResultsByBundleData.get(bundleInput);
  if (!sendResult) {
    throw new Error(
      "Atomic interop execution requires an InteropSendResult (or bundleData) returned by " +
        "sendInteropBundle/sendInteropMessage in this process, so the atomic flow metadata is known"
    );
  }
  return sendResult;
}

/**
 * Unbundle a bundle on the destination chain via InteropHandler.unbundleBundle.
 */
export async function unbundleBundle(
  destProvider: providers.JsonRpcProvider,
  bundleData: string,
  callStatuses: number[],
  signerKey?: string
): Promise<ethers.providers.TransactionReceipt> {
  const wallet = new Wallet(signerKey || getInteropSourcePrivateKey(), destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), wallet);

  const tx = await interopHandler.unbundleBundle(bundleData, callStatuses, { gasLimit: DEFAULT_TX_GAS_LIMIT });
  return tx.wait();
}

/**
 * Simulate InteropHandler.unbundleBundle via callStatic to capture revert data without sending a tx.
 */
export async function simulateUnbundleBundle(
  destProvider: providers.JsonRpcProvider,
  bundleData: string,
  callStatuses: number[],
  signerKey?: string
): Promise<void> {
  const wallet = new Wallet(signerKey || getInteropSourcePrivateKey(), destProvider);
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), wallet);

  await interopHandler.callStatic.unbundleBundle(bundleData, callStatuses, { gasLimit: DEFAULT_TX_GAS_LIMIT });
}

/**
 * Query bundle status from InteropHandler.
 */
export async function getBundleStatus(provider: providers.JsonRpcProvider, bundleHash: string): Promise<number> {
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), provider);
  const result = await interopHandler.bundleStatus(bundleHash);
  return typeof result === "number" ? result : result.toNumber();
}

/**
 * Query individual call status from InteropHandler.
 */
export async function getCallStatus(
  provider: providers.JsonRpcProvider,
  bundleHash: string,
  callIndex: number
): Promise<number> {
  const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("L2InteropHandler"), provider);
  const result = await interopHandler.callStatus(bundleHash, callIndex);
  return typeof result === "number" ? result : result.toNumber();
}

/**
 * Get the interop protocol fee from InteropCenter.
 */
export async function getInteropProtocolFee(provider: providers.JsonRpcProvider): Promise<BigNumber> {
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  return interopCenter.interopProtocolFee();
}

/**
 * Set the dynamic interop protocol fee through the bootloader-only production entry point.
 */
export async function setInteropProtocolFee(provider: providers.JsonRpcProvider, fee: BigNumber): Promise<void> {
  if (isLiveInteropMode()) {
    throw new Error("setInteropProtocolFee uses Anvil bootloader impersonation and cannot run in live mode");
  }

  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  await impersonateAndRun(provider, L2_BOOTLOADER_ADDR, async (signer) => {
    const tx = await interopCenter.connect(signer).setInteropFee(fee, { gasLimit: 500_000 });
    await tx.wait();
  });

  const actualFee = await interopCenter.interopProtocolFee();
  expect(actualFee.eq(fee), `InteropCenter fee should be ${fee.toString()}, got ${actualFee.toString()}`).to.be.true;
}

/**
 * Get accumulated base-token interop fees for a coinbase address.
 */
export async function getAccumulatedProtocolFees(
  provider: providers.JsonRpcProvider,
  coinbase: string
): Promise<BigNumber> {
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  return interopCenter.accumulatedProtocolFees(coinbase);
}

/**
 * Snapshot the current block coinbase's accumulated dynamic interop protocol fees.
 */
export async function snapshotAccumulatedProtocolFees(
  provider: providers.JsonRpcProvider
): Promise<AccumulatedProtocolFeesSnapshot> {
  const latestBlock = await provider.getBlock("latest");
  return {
    coinbase: latestBlock.miner,
    amount: await getAccumulatedProtocolFees(provider, latestBlock.miner),
  };
}

/**
 * Assert the exact dynamic-fee delta credited by a transaction.
 */
export async function expectAccumulatedProtocolFeeDelta(
  provider: providers.JsonRpcProvider,
  before: AccumulatedProtocolFeesSnapshot,
  receipt: providers.TransactionReceipt,
  expectedDelta: BigNumber,
  label: string
): Promise<void> {
  const minedBlock = await provider.getBlock(receipt.blockNumber);
  expect(minedBlock.miner.toLowerCase(), `${label}: transaction mined by snapshotted coinbase`).to.equal(
    before.coinbase.toLowerCase()
  );

  const after = await getAccumulatedProtocolFees(provider, minedBlock.miner);
  const actualDelta = after.sub(before.amount);
  expect(actualDelta.eq(expectedDelta), `${label}: protocol fee delta ${actualDelta} == ${expectedDelta}`).to.be.true;
}

/**
 * Get the fixed ZK interop fee from InteropCenter.
 */
export async function getZkInteropFee(provider: providers.JsonRpcProvider): Promise<BigNumber> {
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  return interopCenter.ZK_INTEROP_FEE();
}

/**
 * Get the configured ZK token asset ID from InteropCenter.
 */
export async function getZkTokenAssetId(provider: providers.JsonRpcProvider): Promise<string> {
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  return interopCenter.ZK_TOKEN_ASSET_ID();
}

/**
 * Get the resolved ZK token address from InteropCenter.
 */
export async function getZkTokenAddress(provider: providers.JsonRpcProvider): Promise<string> {
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  return interopCenter.getZKTokenAddress();
}

/**
 * Get accumulated ZK fees for a coinbase address.
 */
export async function getAccumulatedZkFees(provider: providers.JsonRpcProvider, coinbase: string): Promise<BigNumber> {
  const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), provider);
  return interopCenter.accumulatedZKFees(coinbase);
}

/**
 * Snapshot the current block coinbase's accumulated fixed ZK interop fees.
 */
export async function snapshotAccumulatedZkFees(
  provider: providers.JsonRpcProvider
): Promise<AccumulatedProtocolFeesSnapshot> {
  const latestBlock = await provider.getBlock("latest");
  return {
    coinbase: latestBlock.miner,
    amount: await getAccumulatedZkFees(provider, latestBlock.miner),
  };
}

/**
 * Assert the exact fixed-ZK-fee delta credited by a transaction.
 */
export async function expectAccumulatedZkFeeDelta(
  provider: providers.JsonRpcProvider,
  before: AccumulatedProtocolFeesSnapshot,
  receipt: providers.TransactionReceipt,
  expectedDelta: BigNumber,
  label: string
): Promise<void> {
  const minedBlock = await provider.getBlock(receipt.blockNumber);
  expect(minedBlock.miner.toLowerCase(), `${label}: transaction mined by snapshotted coinbase`).to.equal(
    before.coinbase.toLowerCase()
  );

  const after = await getAccumulatedZkFees(provider, minedBlock.miner);
  const actualDelta = after.sub(before.amount);
  expect(actualDelta.eq(expectedDelta), `${label}: accumulated ZK fee delta ${actualDelta} == ${expectedDelta}`).to.be
    .true;
}

/**
 * Deploy a DummyInteropRecipient contract on a chain.
 * This contract implements IERC7786Recipient.receiveMessage and can receive ETH.
 * Required as the destination for direct-call bundles (value transfers).
 * Source: contracts/dev-contracts/test/DummyInteropRecipient.sol
 */
export async function deployDummyInteropRecipient(
  provider: providers.JsonRpcProvider,
  signerKey?: string
): Promise<string> {
  const wallet = new Wallet(signerKey || getInteropSourcePrivateKey(), provider);
  const factory = new ethers.ContractFactory(
    getAbi("DummyInteropRecipient"),
    getCreationBytecode("DummyInteropRecipient"),
    wallet
  );
  const contract = await factory.deploy();
  await contract.deployed();
  return contract.address;
}

/**
 * Deploy a minimal contract that reverts on any call.
 * Used to create deterministic failing calls in unbundle tests.
 *
 * Bytecode: PUSH1 0x00 PUSH1 0x00 REVERT (runtime: 0x60006000fd)
 * Init code: deploys the revert bytecode as runtime code.
 */
export async function deployRevertingContract(
  provider: providers.JsonRpcProvider,
  signerKey?: string
): Promise<string> {
  const wallet = new Wallet(signerKey || getInteropSourcePrivateKey(), provider);
  // Init code that returns 0x60006000fd as the deployed runtime code
  // PUSH5 0x60006000fd PUSH1 0x00 MSTORE PUSH1 0x05 PUSH1 0x1b RETURN
  const initCode = "0x6460006000fd6000526005601bf3";
  const tx = await wallet.sendTransaction({ data: initCode });
  const receipt = await tx.wait();
  if (!receipt.contractAddress) throw new Error("Failed to deploy reverting contract");
  return receipt.contractAddress;
}

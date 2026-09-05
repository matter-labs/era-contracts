import type { BigNumberish, BytesLike } from "ethers";
import { ethers } from "ethers";
import { getAbi } from "./contracts";

/** Direct L1 message parameters; mirrors deploy-scripts/utils/L1InteropRequests.sol. */
export interface L1L2MessageParams {
  chainId: BigNumberish;
  mintValue: BigNumberish;
  l2Contract: string;
  l2Value: BigNumberish;
  l2Calldata: BytesLike;
  l2GasLimit: BigNumberish;
  l2GasPerPubdataByteLimit: BigNumberish;
  factoryDeps: BytesLike[];
  refundRecipient: string;
}

/** Indirect L1 message parameters. */
export interface L1L2IndirectMessageParams {
  chainId: BigNumberish;
  mintValue: BigNumberish;
  l2Value: BigNumberish;
  l2GasLimit: BigNumberish;
  l2GasPerPubdataByteLimit: BigNumberish;
  refundRecipient: string;
  crossChainSender: string;
  indirectCallValue: BigNumberish;
  indirectCallData: BytesLike;
}

/** Arguments for `L1InteropCenter.sendMessage(recipient, payload, attributes)`. */
export interface InteropSendMessageArgs {
  recipient: string;
  payload: string;
  attributes: string[];
}

let cachedAttributesInterface: ethers.utils.Interface | undefined;

/** ERC-7786 attributes are encoded as calls to IERC7786Attributes functions. */
function attributesInterface(): ethers.utils.Interface {
  if (!cachedAttributesInterface) {
    cachedAttributesInterface = new ethers.utils.Interface(getAbi("IERC7786Attributes"));
  }
  return cachedAttributesInterface;
}

/**
 * Matches `InteroperableAddress.formatEvmV1(chainId, addr)`
 * (contracts/vendor/draft-InteroperableAddress.sol): the ERC-7930 EVM v1
 * interoperable address of (chainId, addr).
 */
export function formatEvmV1(chainId: BigNumberish, addr: string): string {
  // Minimal big-endian chain reference; ethers BigNumber hex is already minimal
  // even-length bytes (e.g. 256 -> 0x0100, 0 -> 0x00), matching `_toChainReference`.
  const chainReference = ethers.BigNumber.from(chainId).toHexString();
  return ethers.utils.hexConcat([
    "0x00010000", // ERC-7930 version 0x0001 + EVM (eip-155) chain type 0x0000
    ethers.utils.hexlify(ethers.utils.hexDataLength(chainReference)),
    chainReference,
    "0x14", // address length: 20 bytes
    addr,
  ]);
}

/**
 * Matches `L1InteropRequests.encodeDirect`: the `sendMessage` arguments for a
 * direct request.
 */
export function encodeDirectInteropRequest(request: L1L2MessageParams): InteropSendMessageArgs {
  const iface = attributesInterface();
  return {
    recipient: formatEvmV1(request.chainId, request.l2Contract),
    payload: ethers.utils.hexlify(request.l2Calldata),
    attributes: [
      iface.encodeFunctionData("l1ToL2TransactionParams", [
        request.mintValue,
        request.l2GasLimit,
        request.l2GasPerPubdataByteLimit,
        request.refundRecipient,
      ]),
      iface.encodeFunctionData("interopCallValue", [request.l2Value]),
      iface.encodeFunctionData("factoryDeps", [request.factoryDeps]),
    ],
  };
}

/**
 * Matches `L1InteropRequests.encodeIndirect`: the `sendMessage` arguments for
 * an indirect request.
 */
export function encodeIndirectInteropRequest(request: L1L2IndirectMessageParams): InteropSendMessageArgs {
  const iface = attributesInterface();
  return {
    recipient: formatEvmV1(request.chainId, request.crossChainSender),
    payload: ethers.utils.hexlify(request.indirectCallData),
    attributes: [
      iface.encodeFunctionData("l1ToL2TransactionParams", [
        request.mintValue,
        request.l2GasLimit,
        request.l2GasPerPubdataByteLimit,
        request.refundRecipient,
      ]),
      iface.encodeFunctionData("interopCallValue", [request.l2Value]),
      iface.encodeFunctionData("indirectCall", [request.indirectCallValue]),
    ],
  };
}

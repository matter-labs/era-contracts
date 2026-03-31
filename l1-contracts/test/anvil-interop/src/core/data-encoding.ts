/**
 * TypeScript mirror of Solidity's DataEncoding library.
 *
 * All encoding functions here match the formats used by
 * contracts/common/libraries/DataEncoding.sol so that off-chain
 * test helpers produce data the contracts can decode.
 */
import type { BigNumber } from "ethers";
import { ethers } from "ethers";
import { L2_NATIVE_TOKEN_VAULT_ADDR } from "./const";

const abiCoder = ethers.utils.defaultAbiCoder;

// Encoding version constants (from IAssetRouterBase.sol)
export const NEW_ENCODING_VERSION = "0x01";

/**
 * Matches `DataEncoding.encodeNTVAssetId(chainId, tokenAddress)`.
 */
export function encodeNtvAssetId(chainId: number, tokenAddress: string): string {
  return ethers.utils.keccak256(
    abiCoder.encode(["uint256", "address", "address"], [chainId, L2_NATIVE_TOKEN_VAULT_ADDR, tokenAddress])
  );
}

/**
 * Matches `DataEncoding.encodeBridgeBurnData(amount, remoteReceiver, maybeTokenAddress)`.
 *
 * Used as `transferData` in bridgehub deposit flows.
 */
export function encodeBridgeBurnData(amount: BigNumber, remoteReceiver: string, maybeTokenAddress: string): string {
  return abiCoder.encode(["uint256", "address", "address"], [amount, remoteReceiver, maybeTokenAddress]);
}

/**
 * Matches `DataEncoding.encodeAssetRouterBridgehubDepositData(assetId, transferData)`.
 *
 * Used as `secondBridgeCalldata` in `requestL2TransactionTwoBridges`.
 */
export function encodeAssetRouterBridgehubDepositData(assetId: string, transferData: string): string {
  return ethers.utils.hexConcat([NEW_ENCODING_VERSION, abiCoder.encode(["bytes32", "bytes"], [assetId, transferData])]);
}

/**
 * Matches `DataEncoding.encodeTokenData(chainId, name, symbol, decimals)`.
 *
 * Used as `erc20Metadata` in bridge mint data.
 */
export function encodeTokenData(
  chainId: number,
  name: string = "0x",
  symbol: string = "0x",
  decimals: string = "0x"
): string {
  return ethers.utils.hexConcat([
    NEW_ENCODING_VERSION,
    abiCoder.encode(["uint256", "bytes", "bytes", "bytes"], [chainId, name, symbol, decimals]),
  ]);
}

/**
 * Matches `DataEncoding.encodeBridgeMintData(originalCaller, remoteReceiver, originToken, amount, erc20Metadata)`.
 *
 * Used as `transferData` in withdrawal / finalize-deposit messages.
 */
export function encodeBridgeMintData(
  originalCaller: string,
  remoteReceiver: string,
  originToken: string,
  amount: BigNumber,
  erc20Metadata: string
): string {
  return abiCoder.encode(
    ["address", "address", "address", "uint256", "bytes"],
    [originalCaller, remoteReceiver, originToken, amount, erc20Metadata]
  );
}

/**
 * Encode a chain ID in ERC-7930 format (EVM chain without address).
 */
export function encodeEvmChain(chainId: number): string {
  let chainIdHex = chainId.toString(16);
  if (chainIdHex.length % 2 !== 0) chainIdHex = `0${chainIdHex}`;
  const chainRefBytes = ethers.utils.arrayify(`0x${chainIdHex}`);
  const chainRefLen = chainRefBytes.length;
  return ethers.utils.hexlify(new Uint8Array([0x00, 0x01, 0x00, 0x00, chainRefLen, ...chainRefBytes, 0x00]));
}

/**
 * Encode an address in ERC-7930 format (EVM address without chain reference).
 */
export function encodeEvmAddress(address: string): string {
  const addrBytes = ethers.utils.arrayify(address);
  return ethers.utils.hexlify(new Uint8Array([0x00, 0x01, 0x00, 0x00, 0x00, 0x14, ...addrBytes]));
}

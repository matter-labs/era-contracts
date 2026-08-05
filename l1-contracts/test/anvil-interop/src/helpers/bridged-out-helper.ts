import type { BigNumber } from "ethers";
import { Contract, providers } from "ethers";
import { getAbi } from "../core/contracts";

/**
 * Helpers for asserting L1NativeTokenVault.bridgedOut in bridge tests. See
 * {protocol-docs/bridging.md#native-token-vault} for the accounting semantics. bridgedOut is per-asset (aggregate
 * across chains), so tests assert the delta around a single operation, not an absolute balance.
 */
function l1NativeTokenVault(l1RpcUrl: string, l1NativeTokenVaultAddr: string): Contract {
  return new Contract(l1NativeTokenVaultAddr, getAbi("L1NativeTokenVault"), new providers.JsonRpcProvider(l1RpcUrl));
}

/** Reads L1NativeTokenVault.bridgedOut(assetId) on L1. */
export async function getL1BridgedOut(
  l1RpcUrl: string,
  l1NativeTokenVaultAddr: string,
  assetId: string
): Promise<BigNumber> {
  return l1NativeTokenVault(l1RpcUrl, l1NativeTokenVaultAddr).bridgedOut(assetId);
}

/** The asset ID of L1's base token (ETH), i.e. the bridgedOut key for ETH bridge flows. */
export async function getL1BaseTokenAssetId(l1RpcUrl: string, l1NativeTokenVaultAddr: string): Promise<string> {
  return l1NativeTokenVault(l1RpcUrl, l1NativeTokenVaultAddr).BASE_TOKEN_ASSET_ID();
}

import type { BigNumber } from "ethers";
import { Contract, providers } from "ethers";
import { getAbi } from "../core/contracts";

/**
 * Helpers for asserting L1NativeTokenVault.bridgedOut in bridge tests.
 *
 * `bridgedOut[assetId]` is the net amount of an L1-native asset currently bridged out of L1.
 * It replaces the removed L1AssetTracker.chainBalance as the on-L1 record of how much has been
 * bridged: it increases on outbound flows (deposits / interop sends) and decreases on inbound
 * ones (withdrawal finalizations / failed-deposit refunds). Unlike a raw balanceOf it only moves
 * through real bridge flows, so it is the value to assert bridge accounting against.
 *
 * Note it is per-asset (aggregate across chains), not per-chain like the old chainBalance, so tests
 * assert the delta around a single operation rather than an absolute per-chain balance.
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

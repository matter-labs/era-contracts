import { BigNumber, Contract, providers } from "ethers";
import type { BalanceSnapshot, ChainBalanceSnapshot, CoreDeployedAddresses, DeploymentState } from "../core/types";
import { getAbi } from "../core/contracts";
import { ETH_TOKEN_ADDRESS, GW_ASSET_TRACKER_ADDR } from "../core/const";

/**
 * Balance tracking across L1AssetTracker, GWAssetTracker, and actual token balances.
 *
 * For each operation (deposit, withdrawal, interop transfer) we snapshot:
 * - Actual ERC20/ETH balances on L1 and L2
 * - L1AssetTracker.chainBalance[chainId][assetId] on L1
 * - GWAssetTracker.chainBalance[chainId][assetId] on GW (for GW-settled chains)
 */
export class BalanceTracker {
  private l1Provider: providers.JsonRpcProvider;
  private l2Providers: Map<number, providers.JsonRpcProvider>;
  private l1AssetTrackerAddr: string;
  private gwChainId: number | undefined;

  constructor(
    l1Provider: providers.JsonRpcProvider,
    l2Providers: Map<number, providers.JsonRpcProvider>,
    l1Addresses: CoreDeployedAddresses,
    gwChainId?: number
  ) {
    this.l1Provider = l1Provider;
    this.l2Providers = l2Providers;
    this.l1AssetTrackerAddr = l1Addresses.l1AssetTracker;
    this.gwChainId = gwChainId;
  }

  /**
   * Read L1AssetTracker.chainBalance(chainId, assetId) on L1.
   */
  async getL1ChainBalance(chainId: number, assetId: string): Promise<BigNumber> {
    const tracker = new Contract(this.l1AssetTrackerAddr, getAbi("L1AssetTracker"), this.l1Provider);
    return tracker.chainBalance(chainId, assetId);
  }

  /**
   * Read GWAssetTracker.chainBalance(chainId, assetId) on the GW chain.
   */
  async getGWChainBalance(chainId: number, assetId: string): Promise<BigNumber> {
    if (!this.gwChainId) {
      throw new Error("GW chain ID not configured");
    }
    const gwProvider = this.l2Providers.get(this.gwChainId);
    if (!gwProvider) {
      throw new Error(`GW provider not found for chain ${this.gwChainId}`);
    }
    const tracker = new Contract(GW_ASSET_TRACKER_ADDR, getAbi("GWAssetTracker"), gwProvider);
    return tracker.chainBalance(chainId, assetId);
  }

  /**
   * Get the provider for a given L2 chain ID.
   */
  getL2Provider(chainId: number): providers.JsonRpcProvider {
    const provider = this.l2Providers.get(chainId);
    if (!provider) {
      throw new Error(`Provider not found for L2 chain ${chainId}`);
    }
    return provider;
  }

  /**
   * Get the L1 provider.
   */
  getL1Provider(): providers.JsonRpcProvider {
    return this.l1Provider;
  }

  /**
   * Read an ERC20 token balance for an address on a given L2 chain.
   */
  async getL2TokenBalance(chainId: number, tokenAddress: string, walletAddress: string): Promise<BigNumber> {
    const provider = this.getL2Provider(chainId);
    const token = new Contract(tokenAddress, getAbi("TestnetERC20Token"), provider);
    return token.balanceOf(walletAddress);
  }

  /**
   * Read an ERC20 token balance for an address on L1.
   */
  async getL1TokenBalance(tokenAddress: string, walletAddress: string): Promise<BigNumber> {
    const token = new Contract(tokenAddress, getAbi("TestnetERC20Token"), this.l1Provider);
    return token.balanceOf(walletAddress);
  }

  /**
   * Read ETH balance for an address on L1.
   */
  async getL1EthBalance(walletAddress: string): Promise<BigNumber> {
    return this.l1Provider.getBalance(walletAddress);
  }

  /**
   * Read ETH balance for an address on a given L2 chain.
   */
  async getL2EthBalance(chainId: number, walletAddress: string): Promise<BigNumber> {
    const provider = this.getL2Provider(chainId);
    return provider.getBalance(walletAddress);
  }

  /**
   * Take a full balance snapshot for a chain + asset.
   *
   * @param chainId - The L2 chain to snapshot
   * @param assetId - The asset ID (keccak256 of chainId + NTV + tokenAddr)
   * @param l1TokenAddress - ERC20 address on L1 (for actual balance)
   * @param l2TokenAddress - ERC20 address on L2 (for actual balance)
   * @param walletAddress - Address to check balances for
   * @param isGWSettled - Whether the chain is settled via GW
   */
  async takeSnapshot(
    chainId: number,
    assetId: string,
    l1TokenAddress: string | undefined,
    l2TokenAddress: string | undefined,
    walletAddress: string,
    isGWSettled: boolean = false
  ): Promise<BalanceSnapshot> {
    const l1TokenBalance =
      l1TokenAddress && l1TokenAddress !== ETH_TOKEN_ADDRESS
        ? await this.getL1TokenBalance(l1TokenAddress, walletAddress)
        : await this.getL1EthBalance(walletAddress);

    const l2TokenBalance =
      l2TokenAddress && l2TokenAddress !== ETH_TOKEN_ADDRESS
        ? await this.getL2TokenBalance(chainId, l2TokenAddress, walletAddress)
        : await this.getL2EthBalance(chainId, walletAddress);

    // Always track L1AssetTracker.chainBalance under the chain's own ID
    const l1ChainBalance = await this.getL1ChainBalance(chainId, assetId);

    const snapshot: BalanceSnapshot = {
      l1TokenBalance: l1TokenBalance.toString(),
      l2TokenBalance: l2TokenBalance.toString(),
      l1ChainBalance: l1ChainBalance.toString(),
    };

    // For GW-settled chains, also track L1AssetTracker.chainBalance under the GW chain ID
    // and GWAssetTracker.chainBalance[chainId]
    if (isGWSettled && this.gwChainId) {
      const l1GwChainBalance = await this.getL1ChainBalance(this.gwChainId, assetId);
      snapshot.l1GwChainBalance = l1GwChainBalance.toString();

      const gwChainBalance = await this.getGWChainBalance(chainId, assetId);
      snapshot.gwChainBalance = gwChainBalance.toString();
    }

    return snapshot;
  }

  /**
   * Take a chain-balance-only snapshot (useful for checking conservation).
   */
  async takeChainBalanceSnapshot(
    chainId: number,
    assetId: string,
    isGWSettled: boolean = false
  ): Promise<ChainBalanceSnapshot> {
    // Always track L1AssetTracker.chainBalance under the chain's own ID
    const l1ChainBalance = await this.getL1ChainBalance(chainId, assetId);

    const result: ChainBalanceSnapshot = {
      l1ChainBalance: l1ChainBalance.toString(),
    };

    // For GW-settled chains, also track L1AssetTracker.chainBalance under the GW chain ID
    // and GWAssetTracker.chainBalance[chainId]
    if (isGWSettled && this.gwChainId) {
      const l1GwChainBalance = await this.getL1ChainBalance(this.gwChainId, assetId);
      result.l1GwChainBalance = l1GwChainBalance.toString();

      const gwChainBalance = await this.getGWChainBalance(chainId, assetId);
      result.gwChainBalance = gwChainBalance.toString();
    }

    return result;
  }
}

/**
 * Compute deltas between two balance snapshots.
 * Returns all deltas (l1Token, l2Token, l1ChainBalance, gwChainBalance if present).
 */
export function computeBalanceDeltas(
  before: BalanceSnapshot,
  after: BalanceSnapshot
): {
  l1TokenDelta: BigNumber;
  l2TokenDelta: BigNumber;
  l1ChainBalanceDelta: BigNumber;
  l1GwChainBalanceDelta?: BigNumber;
  gwChainBalanceDelta?: BigNumber;
} {
  const l1TokenDelta = BigNumber.from(after.l1TokenBalance).sub(before.l1TokenBalance);
  const l2TokenDelta = BigNumber.from(after.l2TokenBalance).sub(before.l2TokenBalance);
  const l1ChainBalanceDelta = BigNumber.from(after.l1ChainBalance).sub(before.l1ChainBalance);

  const result: ReturnType<typeof computeBalanceDeltas> = {
    l1TokenDelta,
    l2TokenDelta,
    l1ChainBalanceDelta,
  };

  if (before.l1GwChainBalance && after.l1GwChainBalance) {
    result.l1GwChainBalanceDelta = BigNumber.from(after.l1GwChainBalance).sub(before.l1GwChainBalance);
  }

  if (before.gwChainBalance && after.gwChainBalance) {
    result.gwChainBalanceDelta = BigNumber.from(after.gwChainBalance).sub(before.gwChainBalance);
  }

  return result;
}

/**
 * Query the ETH asset ID from the L1NativeTokenVault contract.
 * The asset ID is deployment-specific (depends on the L1NTV address).
 */
export async function queryEthAssetId(
  l1Provider: providers.JsonRpcProvider,
  l1NativeTokenVaultAddr: string
): Promise<string> {
  const ntv = new Contract(l1NativeTokenVaultAddr, getAbi("L1NativeTokenVault"), l1Provider);
  return ntv.assetId(ETH_TOKEN_ADDRESS);
}

/**
 * Query the ETH asset ID directly from deployment state (convenience wrapper).
 */
export async function queryEthAssetIdFromState(state: DeploymentState): Promise<string> {
  if (!state.chains?.l1 || !state.l1Addresses) {
    throw new Error("Deployment state missing chains or l1Addresses");
  }
  const l1Provider = new providers.JsonRpcProvider(state.chains.l1.rpcUrl);
  return queryEthAssetId(l1Provider, state.l1Addresses.l1NativeTokenVault);
}

/**
 * Create a BalanceTracker from deployment state.
 */
export function createBalanceTrackerFromState(state: DeploymentState): BalanceTracker {
  if (!state.chains || !state.l1Addresses) {
    throw new Error("Deployment state missing chains or l1Addresses");
  }

  const l1Provider = new providers.JsonRpcProvider(state.chains.l1!.rpcUrl);
  const l2Providers = new Map<number, providers.JsonRpcProvider>();

  for (const l2 of state.chains.l2) {
    l2Providers.set(l2.chainId, new providers.JsonRpcProvider(l2.rpcUrl));
  }

  const gwChainId = state.chains.config.find((c) => c.role === "gateway")?.chainId;

  return new BalanceTracker(l1Provider, l2Providers, state.l1Addresses, gwChainId);
}

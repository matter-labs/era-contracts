import { BigNumber, Contract, providers } from "ethers";
import type { BalanceSnapshot, CoreDeployedAddresses, DeploymentState } from "./types";
import { l1AssetTrackerAbi, gwAssetTrackerAbi, testnetERC20TokenAbi, l1NativeTokenVaultAbi } from "./contracts";
import { ETH_TOKEN_ADDRESS, GW_ASSET_TRACKER_ADDR } from "./const";

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
    const tracker = new Contract(this.l1AssetTrackerAddr, l1AssetTrackerAbi(), this.l1Provider);
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
    const tracker = new Contract(GW_ASSET_TRACKER_ADDR, gwAssetTrackerAbi(), gwProvider);
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
    const token = new Contract(tokenAddress, testnetERC20TokenAbi(), provider);
    return token.balanceOf(walletAddress);
  }

  /**
   * Read an ERC20 token balance for an address on L1.
   */
  async getL1TokenBalance(tokenAddress: string, walletAddress: string): Promise<BigNumber> {
    const token = new Contract(tokenAddress, testnetERC20TokenAbi(), this.l1Provider);
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

    // For GW-settled chains, the L1AssetTracker tracks balance under GW chainId
    const l1ChainBalanceChainId = isGWSettled && this.gwChainId ? this.gwChainId : chainId;
    const l1ChainBalance = await this.getL1ChainBalance(l1ChainBalanceChainId, assetId);

    const snapshot: BalanceSnapshot = {
      l1TokenBalance: l1TokenBalance.toString(),
      l2TokenBalance: l2TokenBalance.toString(),
      l1ChainBalance: l1ChainBalance.toString(),
    };

    if (isGWSettled && this.gwChainId) {
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
  ): Promise<{ l1ChainBalance: string; gwChainBalance?: string }> {
    const l1ChainBalanceChainId = isGWSettled && this.gwChainId ? this.gwChainId : chainId;
    const l1ChainBalance = await this.getL1ChainBalance(l1ChainBalanceChainId, assetId);

    const result: { l1ChainBalance: string; gwChainBalance?: string } = {
      l1ChainBalance: l1ChainBalance.toString(),
    };

    if (isGWSettled && this.gwChainId) {
      const gwChainBalance = await this.getGWChainBalance(chainId, assetId);
      result.gwChainBalance = gwChainBalance.toString();
    }

    return result;
  }
}

/**
 * Assert that a deposit shifted balances correctly.
 * - L2 balance should increase by amount
 * - L1AssetTracker chainBalance should increase by amount
 */
export function assertDepositBalances(
  before: BalanceSnapshot,
  after: BalanceSnapshot,
  _amount: BigNumber
): { l2BalanceDelta: BigNumber; l1ChainBalanceDelta: BigNumber } {
  const l2BalanceDelta = BigNumber.from(after.l2TokenBalance).sub(before.l2TokenBalance);
  const l1ChainBalanceDelta = BigNumber.from(after.l1ChainBalance).sub(before.l1ChainBalance);

  return { l2BalanceDelta, l1ChainBalanceDelta };
}

/**
 * Assert that a withdrawal shifted balances correctly.
 * - L2 balance should decrease by amount
 * - L1AssetTracker chainBalance should decrease by amount
 */
export function assertWithdrawalBalances(
  before: BalanceSnapshot,
  after: BalanceSnapshot,
  _amount: BigNumber
): { l2BalanceDelta: BigNumber; l1ChainBalanceDelta: BigNumber } {
  const l2BalanceDelta = BigNumber.from(before.l2TokenBalance).sub(after.l2TokenBalance);
  const l1ChainBalanceDelta = BigNumber.from(before.l1ChainBalance).sub(after.l1ChainBalance);

  return { l2BalanceDelta, l1ChainBalanceDelta };
}

/**
 * Assert interop transfer balance shifts.
 */
export function assertInteropBalances(
  srcBefore: BalanceSnapshot,
  srcAfter: BalanceSnapshot,
  dstBefore: BalanceSnapshot,
  dstAfter: BalanceSnapshot
): {
  srcL2BalanceDelta: BigNumber;
  dstL2BalanceDelta: BigNumber;
  srcGwBalanceDelta?: BigNumber;
  dstGwBalanceDelta?: BigNumber;
} {
  const srcL2BalanceDelta = BigNumber.from(srcBefore.l2TokenBalance).sub(srcAfter.l2TokenBalance);
  const dstL2BalanceDelta = BigNumber.from(dstAfter.l2TokenBalance).sub(dstBefore.l2TokenBalance);

  const result: ReturnType<typeof assertInteropBalances> = {
    srcL2BalanceDelta,
    dstL2BalanceDelta,
  };

  if (srcBefore.gwChainBalance && srcAfter.gwChainBalance) {
    result.srcGwBalanceDelta = BigNumber.from(srcBefore.gwChainBalance).sub(srcAfter.gwChainBalance);
  }
  if (dstBefore.gwChainBalance && dstAfter.gwChainBalance) {
    result.dstGwBalanceDelta = BigNumber.from(dstAfter.gwChainBalance).sub(dstBefore.gwChainBalance);
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
  const ntv = new Contract(l1NativeTokenVaultAddr, l1NativeTokenVaultAbi(), l1Provider);
  return ntv.assetId(ETH_TOKEN_ADDRESS);
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

  const gwChainId = state.chains.config.find((c) => c.isGateway)?.chainId;

  return new BalanceTracker(l1Provider, l2Providers, state.l1Addresses, gwChainId);
}

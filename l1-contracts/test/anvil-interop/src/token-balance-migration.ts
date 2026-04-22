import { BigNumber, Contract, providers } from "ethers";
import type { CoreDeployedAddresses } from "./types";
import { l1AssetTrackerAbi, gwAssetTrackerAbi } from "./contracts";
import { GW_ASSET_TRACKER_ADDR } from "./const";

/**
 * Token balance migration helper.
 *
 * When a chain migrates from L1 settlement to GW settlement, the chain's
 * token balances tracked in L1AssetTracker need to be migrated to GWAssetTracker.
 *
 * In production, this happens through:
 * 1. L2AssetTracker.initiateL1ToGatewayMigrationOnL2() - starts migration on L2
 * 2. L1AssetTracker.receiveL1ToGatewayMigrationOnL1() - finalizes on L1
 * 3. GWAssetTracker.confirmMigrationOnGateway() - confirms on GW
 *
 * For Anvil testing, we can simulate this by directly setting storage or
 * by using impersonation to call the relevant functions.
 */
export class TokenBalanceMigration {
  private l1Provider: providers.JsonRpcProvider;
  private gwProvider: providers.JsonRpcProvider;
  private l1Addresses: CoreDeployedAddresses;
  private gwChainId: number;

  constructor(l1RpcUrl: string, gwRpcUrl: string, l1Addresses: CoreDeployedAddresses, gwChainId: number) {
    this.l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    this.gwProvider = new providers.JsonRpcProvider(gwRpcUrl);
    this.l1Addresses = l1Addresses;
    this.gwChainId = gwChainId;
  }

  /**
   * Read the current chain balance from L1AssetTracker.
   */
  async getL1ChainBalance(chainId: number, assetId: string): Promise<BigNumber> {
    const tracker = new Contract(this.l1Addresses.l1AssetTracker, l1AssetTrackerAbi(), this.l1Provider);
    return tracker.chainBalance(chainId, assetId);
  }

  /**
   * Read the current chain balance from GWAssetTracker.
   */
  async getGWChainBalance(chainId: number, assetId: string): Promise<BigNumber> {
    const tracker = new Contract(GW_ASSET_TRACKER_ADDR, gwAssetTrackerAbi(), this.gwProvider);
    return tracker.chainBalance(chainId, assetId);
  }

  /**
   * Verify that token balances are consistent after migration.
   *
   * After a chain migrates to GW settlement:
   * - L1AssetTracker.chainBalance[gwChainId][assetId] should hold the total for all GW-settled chains
   * - GWAssetTracker.chainBalance[chainId][assetId] should track per-chain balances within GW
   * - Sum of GWAssetTracker balances should <= L1AssetTracker.chainBalance[gwChainId][assetId]
   */
  async verifyMigrationConsistency(
    migratedChainIds: number[],
    assetId: string
  ): Promise<{
    l1GWBalance: BigNumber;
    gwChainBalances: Map<number, BigNumber>;
    gwTotalBalance: BigNumber;
    isConsistent: boolean;
  }> {
    const l1GWBalance = await this.getL1ChainBalance(this.gwChainId, assetId);

    const gwChainBalances = new Map<number, BigNumber>();
    let gwTotalBalance = BigNumber.from(0);

    for (const chainId of migratedChainIds) {
      const balance = await this.getGWChainBalance(chainId, assetId);
      gwChainBalances.set(chainId, balance);
      gwTotalBalance = gwTotalBalance.add(balance);
    }

    // Sum of GW chain balances should be <= L1's GW chain balance
    const isConsistent = gwTotalBalance.lte(l1GWBalance);

    return {
      l1GWBalance,
      gwChainBalances,
      gwTotalBalance,
      isConsistent,
    };
  }
}

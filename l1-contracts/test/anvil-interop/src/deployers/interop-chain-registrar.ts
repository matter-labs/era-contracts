import type { providers } from "ethers";
import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_BRIDGEHUB_ADDR } from "../core/const";
import type { CoreDeployedAddresses } from "../core/types";
import { createProvider } from "../core/utils";
import { syncL1Reads } from "../helpers/l1-reads";

/**
 * Opts chains into interop through the real L1 flow, see {protocol-docs/interop-gating.md#order-per-chain}.
 * The default Anvil account sends the chain admin calls and the Bridgehub, vault and `ChainRegistrationSender` owner
 * calls, so it must be the chain admin and all three owners. After each gating change the interop chains import a new
 * L1 anchor ({syncL1Reads}), as they would on their own.
 */
export class InteropChainRegistrar {
  private l1Wallet: ethers.Wallet;
  private l1Addresses: CoreDeployedAddresses;
  private l2Providers: Map<number, providers.JsonRpcProvider>;

  /**
   * @param l2RpcUrlsByChainId The interop chains' L2s, which read the gating state from L1.
   */
  constructor(l1RpcUrl: string, l1Addresses: CoreDeployedAddresses, l2RpcUrlsByChainId: Map<number, string>) {
    this.l1Wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, createProvider(l1RpcUrl));
    this.l1Addresses = l1Addresses;
    this.l2Providers = new Map([...l2RpcUrlsByChainId].map(([chainId, url]) => [chainId, createProvider(url)]));
  }

  /** The interop chains import a new anchor and read L1 at it. */
  async syncL1Reads(): Promise<void> {
    await syncL1Reads({
      l1Provider: this.l1Wallet.provider as providers.JsonRpcProvider,
      l1Addresses: this.l1Addresses,
      chainIds: [...this.l2Providers.keys()],
      l2Providers: this.l2Providers,
    });
  }

  async enableInterop(chainId: number, diamondProxy: string): Promise<void> {
    const zkChain = new ethers.Contract(diamondProxy, getAbi("IZKChain"), this.l1Wallet);
    const messageRoot = new ethers.Contract(this.l1Addresses.messageRoot, getAbi("L1MessageRoot"), this.l1Wallet);
    const l1Bridgehub = new ethers.Contract(this.l1Addresses.bridgehub, getAbi("L1Bridgehub"), this.l1Wallet);
    const ntv = new ethers.Contract(this.l1Addresses.l1NativeTokenVault, getAbi("L1NativeTokenVault"), this.l1Wallet);
    // When interop is enabled, a chain holds only ETH and its base token. The chains are created on this release,
    // so the vault's counters cover their whole history and nothing is backfilled.
    const assetIds: string[] = [
      ...new Set<string>([await ntv.BASE_TOKEN_ASSET_ID(), await l1Bridgehub.baseTokenAssetId(chainId)]),
    ];

    await this.requireChainAdmin(zkChain);
    await (await zkChain.permanentlyRequireSecondProofSystem()).wait();
    // `enableInterop` requires it, see {protocol-docs/l1sload.md#chain-config-flag}.
    await (await zkChain.setZKsyncOSL1SloadEnabled(true)).wait();
    await (await messageRoot.enableInterop(chainId, true)).wait();
    for (const assetId of assetIds) {
      await (await ntv.moveChainBalanceToInteropPool(chainId, assetId)).wait();
    }

    if (
      !(await zkChain.isSecondProofSystemRequired()) ||
      !(await zkChain.isZKsyncOSL1SloadEnabled()) ||
      !(await messageRoot.isInteropEnabled(chainId))
    ) {
      throw new Error(
        `Enabling interop for chain ${chainId} did not require the second proof system, enable L1SLOAD and enable interop`
      );
    }
    for (const assetId of assetIds) {
      if (!(await ntv.chainBalanceInInteropPool(chainId, assetId))) {
        throw new Error(`Chain ${chainId} balance of asset ${assetId} was not moved to the interop pool`);
      }
    }
    console.log(
      `   ✅ Chain ${chainId}: second proof system required, L1SLOAD and interop enabled, balances moved to the interop pool`
    );
  }

  async allowInteropPeer(
    chainId: number,
    peerChainId: number,
    diamondProxy: string,
    l2Provider: providers.JsonRpcProvider
  ): Promise<void> {
    const sender = new ethers.Contract(
      this.l1Addresses.chainRegistrationSender,
      getAbi("ChainRegistrationSender"),
      this.l1Wallet
    );
    const l1Bridgehub = new ethers.Contract(this.l1Addresses.bridgehub, getAbi("L1Bridgehub"), this.l1Wallet);
    const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), l2Provider);

    await this.requireChainAdmin(new ethers.Contract(diamondProxy, getAbi("IZKChain"), this.l1Wallet));
    await (await sender.allowInteropPeer(chainId, peerChainId)).wait();
    await this.syncL1Reads();

    const expectedAssetId: string = await l1Bridgehub.baseTokenAssetId(peerChainId);
    if (
      !(await sender.interopPeerAllowed(chainId, peerChainId)) ||
      (await sender.interopBaseTokenAssetId(peerChainId)) !== expectedAssetId
    ) {
      throw new Error(`Chain ${chainId} did not record chain ${peerChainId} as an allowed peer`);
    }
    if (
      (await l2Bridgehub.interopBaseTokenAssetId(peerChainId)) !== expectedAssetId ||
      !(await l2Bridgehub.isPeerAllowed(peerChainId))
    ) {
      throw new Error(`Chain ${chainId} does not read chain ${peerChainId} as an allowed peer`);
    }
    console.log(`   ✅ Chain ${chainId}: chain ${peerChainId} allowed as interop peer`);
  }

  /**
   * Governance removes the pair (`chainId`, `peerChainId`) from `chainId`'s side, see
   * {protocol-docs/interop-gating.md#interop-peer-whitelist}.
   */
  async deregisterInteropPair(
    chainId: number,
    peerChainId: number,
    l2Provider: providers.JsonRpcProvider
  ): Promise<void> {
    const sender = new ethers.Contract(
      this.l1Addresses.chainRegistrationSender,
      getAbi("ChainRegistrationSender"),
      this.l1Wallet
    );
    const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), l2Provider);

    await this.requireChainRegistrationSenderOwner(sender);
    await (await sender.deregisterInteropPairs(chainId, [peerChainId])).wait();
    await this.syncL1Reads();

    if (await sender.interopPeerAllowed(chainId, peerChainId)) {
      throw new Error(`Chain ${chainId} still records chain ${peerChainId} as an allowed peer`);
    }
    // The snapshot stays: it registers the peer for interop, see {protocol-docs/l1sload.md#the-base-token-snapshot}.
    if (await l2Bridgehub.isPeerAllowed(peerChainId)) {
      throw new Error(`Chain ${chainId} still reads chain ${peerChainId} as an allowed peer`);
    }
    console.log(`   ✅ Chain ${chainId}: chain ${peerChainId} deregistered`);
  }

  /**
   * Governance suspends (`suspended`) or resumes chain `chainId`'s interop, see
   * {protocol-docs/l1sload.md#suspending-a-chain}.
   */
  async setInteropSuspended(chainId: number, suspended: boolean): Promise<void> {
    const sender = new ethers.Contract(
      this.l1Addresses.chainRegistrationSender,
      getAbi("ChainRegistrationSender"),
      this.l1Wallet
    );
    await this.requireChainRegistrationSenderOwner(sender);
    await (await (suspended ? sender.suspendInterop(chainId) : sender.resumeInterop(chainId))).wait();
    await this.syncL1Reads();

    if ((await sender.isInteropSuspended(chainId)) !== suspended) {
      throw new Error(`Chain ${chainId} is ${suspended ? "not" : "still"} suspended on L1`);
    }
    console.log(`   ✅ Chain ${chainId}: interop ${suspended ? "suspended" : "resumed"}`);
  }

  private async requireChainRegistrationSenderOwner(sender: ethers.Contract): Promise<void> {
    const owner: string = await sender.owner();
    if (owner !== this.l1Wallet.address) {
      throw new Error(`ChainRegistrationSender owner is ${owner}, not the default Anvil account`);
    }
  }

  private async requireChainAdmin(zkChain: ethers.Contract): Promise<void> {
    const admin: string = await zkChain.getAdmin();
    if (admin !== this.l1Wallet.address) {
      throw new Error(`Chain admin of ${zkChain.address} is ${admin}, not the default Anvil account`);
    }
  }
}

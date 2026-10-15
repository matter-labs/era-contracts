import type { providers } from "ethers";
import { ethers } from "ethers";
import { getAbi } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, L2_BRIDGEHUB_ADDR } from "../core/const";
import type { CoreDeployedAddresses } from "../core/types";
import { relayPriorityRequestsToChain, createProvider } from "../core/utils";

/**
 * Opts chains into interop through the real L1 flow, see {protocol-docs/interop-gating.md#order-per-chain}.
 * The default Anvil account sends both the chain admin calls and the Bridgehub owner call, so it must be
 * the chain admin and the Bridgehub owner.
 */
export class InteropChainRegistrar {
  private l1Wallet: ethers.Wallet;
  private l1Addresses: CoreDeployedAddresses;

  constructor(l1RpcUrl: string, l1Addresses: CoreDeployedAddresses) {
    this.l1Wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, createProvider(l1RpcUrl));
    this.l1Addresses = l1Addresses;
  }

  async enableInterop(chainId: number, diamondProxy: string): Promise<void> {
    const zkChain = new ethers.Contract(diamondProxy, getAbi("IZKChain"), this.l1Wallet);
    const messageRoot = new ethers.Contract(this.l1Addresses.messageRoot, getAbi("L1MessageRoot"), this.l1Wallet);

    await this.requireChainAdmin(zkChain);
    await (await zkChain.lockSecondProofSystem()).wait();
    await (await messageRoot.enableInterop(chainId)).wait();

    if (!(await zkChain.isSecondProofSystemLocked()) || !(await messageRoot.isInteropEnabled(chainId))) {
      throw new Error(`Enabling interop for chain ${chainId} did not lock the proof system and enable interop`);
    }
    console.log(`   ✅ Chain ${chainId}: second proof system locked, interop enabled`);
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
    const l1Receipt = await (await sender.setInteropPeer(chainId, peerChainId, true)).wait();
    await relayPriorityRequestsToChain(l1Receipt, diamondProxy, l2Provider);

    const expectedAssetId: string = await l1Bridgehub.baseTokenAssetId(peerChainId);
    if (!(await sender.interopPeerAllowed(chainId, peerChainId))) {
      throw new Error(`Chain ${chainId} did not record chain ${peerChainId} as an allowed peer`);
    }
    if ((await l2Bridgehub.baseTokenAssetId(peerChainId)) !== expectedAssetId) {
      throw new Error(`Chain ${peerChainId} is not registered on the L2Bridgehub of chain ${chainId}`);
    }
    console.log(`   ✅ Chain ${chainId}: chain ${peerChainId} allowed as interop peer`);
  }

  private async requireChainAdmin(zkChain: ethers.Contract): Promise<void> {
    const admin: string = await zkChain.getAdmin();
    if (admin !== this.l1Wallet.address) {
      throw new Error(`Chain admin of ${zkChain.address} is ${admin}, not the default Anvil account`);
    }
  }
}

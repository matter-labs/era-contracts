import { ethers, providers } from "ethers";
import { encodeNtvAssetId } from "../core/data-encoding";
import { getAbi } from "../core/contracts";
import { ANVIL_DEFAULT_PRIVATE_KEY, ETH_TOKEN_ADDRESS, L1_CHAIN_ID, L2_BRIDGEHUB_ADDR } from "../core/const";
import { relayPriorityRequestsToChain } from "../core/utils";

export class InteropChainRegistrar {
  private l1Provider: providers.JsonRpcProvider;
  private l2Provider: providers.JsonRpcProvider;
  private chainRegistrationSenderAddr: string;
  private currentChainDiamondProxy: string;

  constructor(l2RpcUrl: string, l1RpcUrl: string, chainRegistrationSender: string, currentChainDiamondProxy: string) {
    this.l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    this.l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
    this.chainRegistrationSenderAddr = chainRegistrationSender;
    this.currentChainDiamondProxy = currentChainDiamondProxy;
  }

  async registerInteropChains(currentChainId: number, interopChainIds: number[]): Promise<void> {
    const chainIds = Array.from(new Set(interopChainIds));

    if (chainIds.length === 0) {
      console.log("   No real interop registrations required for this chain");
      return;
    }

    const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), this.l2Provider);
    const l1Wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, this.l1Provider);
    const chainRegistrationSender = new ethers.Contract(
      this.chainRegistrationSenderAddr,
      getAbi("ChainRegistrationSender"),
      l1Wallet
    );

    for (const chainId of chainIds) {
      const existingAssetId = await l2Bridgehub.baseTokenAssetId(chainId);
      if (existingAssetId !== ethers.constants.HashZero) {
        console.log(`   ✅ Chain ${chainId} already registered on L2Bridgehub`);
        continue;
      }

      console.log(`   Registering chain ${chainId} on chain ${currentChainId} via L1 ChainRegistrationSender...`);

      // ChainRegistrationSender.registerChain has no access control,
      // so any EOA can call it directly -- no impersonation needed.
      const tx = await chainRegistrationSender.registerChain(chainId, currentChainId, {
        gasLimit: 5_000_000,
      });
      const l1Receipt = await tx.wait();

      await relayPriorityRequestsToChain(l1Receipt, this.currentChainDiamondProxy, this.l2Provider);

      const registeredAssetId = await l2Bridgehub.baseTokenAssetId(chainId);
      const expectedAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
      if (registeredAssetId !== expectedAssetId) {
        throw new Error(
          `Real interop registration failed for chain ${chainId} on chain ${currentChainId}: ` +
            `expected ${expectedAssetId}, got ${registeredAssetId}`
        );
      }
      console.log(`   ✅ Chain ${chainId} registered on L2Bridgehub via real L1 flow`);
    }
  }
}

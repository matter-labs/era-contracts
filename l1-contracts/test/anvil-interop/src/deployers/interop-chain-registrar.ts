import { ethers, providers } from "ethers";
import { encodeNtvAssetId } from "../core/data-encoding";
import { getAbi } from "../core/contracts";
import { ETH_TOKEN_ADDRESS, L1_CHAIN_ID, L2_BRIDGEHUB_ADDR } from "../core/const";
import { extractAndRelayNewPriorityRequests, impersonateAndRun } from "../core/utils";

export class InteropChainRegistrar {
  private l1Provider: providers.JsonRpcProvider;
  private l2Provider: providers.JsonRpcProvider;
  private chainRegistrationSender: string;
  private currentChainDiamondProxy: string;

  constructor(l2RpcUrl: string, l1RpcUrl: string, chainRegistrationSender: string, currentChainDiamondProxy: string) {
    this.l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
    this.l2Provider = new providers.JsonRpcProvider(l2RpcUrl);
    this.chainRegistrationSender = chainRegistrationSender;
    this.currentChainDiamondProxy = currentChainDiamondProxy;
  }

  private getInteropRegistrationSender(chainId: number): string {
    return ethers.utils.getAddress(
      ethers.utils.hexDataSlice(ethers.utils.keccak256(ethers.utils.toUtf8Bytes(`interop-registration:${chainId}`)), 12)
    );
  }

  async registerInteropChains(currentChainId: number, interopChainIds: number[]): Promise<void> {
    const chainIds = Array.from(new Set(interopChainIds));

    if (chainIds.length === 0) {
      console.log("   No real interop registrations required for this chain");
      return;
    }

    const l2Bridgehub = new ethers.Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), this.l2Provider);
    const chainRegistrationSender = new ethers.Contract(
      this.chainRegistrationSender,
      getAbi("ChainRegistrationSender"),
      this.l1Provider
    );

    for (const chainId of chainIds) {
      const existingAssetId = await l2Bridgehub.baseTokenAssetId(chainId);
      if (existingAssetId !== ethers.constants.HashZero) {
        console.log(`   ✅ Chain ${chainId} already registered on L2Bridgehub`);
        continue;
      }

      console.log(`   Registering chain ${chainId} on chain ${currentChainId} via L1 ChainRegistrationSender...`);
      const sender = this.getInteropRegistrationSender(currentChainId);

      const l1Receipt = await impersonateAndRun(this.l1Provider, sender, async (signer) => {
        const tx = await chainRegistrationSender.connect(signer).registerChain(chainId, currentChainId, {
          gasLimit: 5_000_000,
        });
        return tx.wait();
      });

      await extractAndRelayNewPriorityRequests(
        l1Receipt,
        [{ diamondProxy: this.currentChainDiamondProxy, provider: this.l2Provider }],
        (line) => console.log(line)
      );

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

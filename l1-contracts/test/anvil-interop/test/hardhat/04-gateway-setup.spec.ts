import { expect } from "chai";
import { Contract, ethers, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getAbi } from "../../src/core/contracts";
import { L2_BRIDGEHUB_ADDR } from "../../src/core/const";
import { getChainIdByRole, getL2Chain } from "../../src/core/utils";

describe("04 - Gateway Deployment Verification (read-only)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwChainId: number;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.ctmAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwChainId = getChainIdByRole(state.chains.config, "gateway");
  });

  // Note: individual contract deployment checks (L2Bridgehub, L2AssetRouter, etc.)
  // are already covered by spec 01 for ALL chains including the gateway.
  // This spec only tests GW-specific state: chain registration and L1 designation.

  describe("GW chain registration", () => {
    let gwProvider: providers.JsonRpcProvider;

    before(() => {
      const gwChain = getL2Chain(state.chains!, gwChainId);
      gwProvider = new providers.JsonRpcProvider(gwChain.rpcUrl);
    });

    it("has GW-settled chains registered on GW L2Bridgehub", async () => {
      const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), gwProvider);

      // Only GW-settled chains should be registered on the GW L2Bridgehub
      for (const chainConfig of state.chains!.config) {
        if (chainConfig.settlement !== "gateway") continue;
        const baseTokenAssetId = await l2Bridgehub.baseTokenAssetId(chainConfig.chainId);
        expect(
          baseTokenAssetId,
          `Chain ${chainConfig.chainId} (${chainConfig.role}) should be registered on GW L2Bridgehub`
        ).to.not.equal(ethers.constants.HashZero);
      }
    });

    it("returns zero for direct-settled chain on GW L2Bridgehub", async () => {
      const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), gwProvider);

      // The direct-settled chain should not be registered on the GW L2Bridgehub
      const directSettledChainId = getChainIdByRole(state.chains!.config, "directSettled");
      const baseTokenAssetId = await l2Bridgehub.baseTokenAssetId(directSettledChainId);
      expect(baseTokenAssetId, "Direct-settled chain should not be registered on GW L2Bridgehub").to.equal(
        ethers.constants.HashZero
      );
    });
  });

  describe("Gateway designation on L1", () => {
    let l1Provider: providers.JsonRpcProvider;

    before(() => {
      l1Provider = new providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
    });

    it("GW chain has diamond proxy on L1", async () => {
      const chainAddr = state.chainAddresses!.find((c) => c.chainId === gwChainId);
      expect(chainAddr, `GW chain ${gwChainId} not found in chainAddresses`).to.exist;
      const code = await l1Provider.getCode(chainAddr!.diamondProxy);
      expect(code).to.not.equal("0x");
    });
  });
});

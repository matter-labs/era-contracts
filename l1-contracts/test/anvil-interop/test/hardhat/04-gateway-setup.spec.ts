import { expect } from "chai";
import { Contract, ethers, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { l1BridgehubAbi, l2BridgehubAbi } from "../../src/contracts";
import {
  L2_BRIDGEHUB_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  GW_ASSET_TRACKER_ADDR,
  INTEROP_CENTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
} from "../../src/const";
import { getChainIdByRole, getL2Chain } from "../../src/utils";

describe("04 - Gateway State Verification", function () {
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

  describe("Gateway chain contracts", () => {
    let gwProvider: providers.JsonRpcProvider;

    before(() => {
      const gwChain = getL2Chain(state.chains!, gwChainId);
      gwProvider = new providers.JsonRpcProvider(gwChain.rpcUrl);
    });

    it("has L2Bridgehub deployed on GW", async () => {
      const code = await gwProvider.getCode(L2_BRIDGEHUB_ADDR);
      expect(code).to.not.equal("0x");
    });

    it("has L2AssetRouter deployed on GW", async () => {
      const code = await gwProvider.getCode(L2_ASSET_ROUTER_ADDR);
      expect(code).to.not.equal("0x");
    });

    it("has L2NativeTokenVault deployed on GW", async () => {
      const code = await gwProvider.getCode(L2_NATIVE_TOKEN_VAULT_ADDR);
      expect(code).to.not.equal("0x");
    });

    it("has GWAssetTracker deployed on GW", async () => {
      const code = await gwProvider.getCode(GW_ASSET_TRACKER_ADDR);
      expect(code).to.not.equal("0x");
    });

    it("has InteropCenter deployed on GW", async () => {
      const code = await gwProvider.getCode(INTEROP_CENTER_ADDR);
      expect(code).to.not.equal("0x");
    });

    it("has InteropHandler deployed on GW", async () => {
      const code = await gwProvider.getCode(L2_INTEROP_HANDLER_ADDR);
      expect(code).to.not.equal("0x");
    });

    it("has registered chains on GW L2Bridgehub", async () => {
      const l2BhAbi = l2BridgehubAbi();
      const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BhAbi, gwProvider);

      // All L2 chains should be registered
      for (const chainConfig of state.chains!.config) {
        if (chainConfig.isL1) continue;
        const baseTokenAssetId = await l2Bridgehub.baseTokenAssetId(chainConfig.chainId);
        expect(
          baseTokenAssetId,
          `Chain ${chainConfig.chainId} (${chainConfig.role}) should be registered on GW L2Bridgehub`
        ).to.not.equal(ethers.constants.HashZero);
      }
    });

    it("returns zero for unregistered chain on GW L2Bridgehub", async () => {
      const l2BhAbi = l2BridgehubAbi();
      const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BhAbi, gwProvider);

      // A non-existent chain should have zero base token asset ID
      const unregisteredChainId = 999999;
      const baseTokenAssetId = await l2Bridgehub.baseTokenAssetId(unregisteredChainId);
      expect(baseTokenAssetId, "Unregistered chain should have zero baseTokenAssetId").to.equal(
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

    it("CTM is registered in Bridgehub", async () => {
      const bridgehubAbi = l1BridgehubAbi();
      const bridgehub = new Contract(state.l1Addresses!.bridgehub, bridgehubAbi, l1Provider);
      const isRegistered = await bridgehub.chainTypeManagerIsRegistered(state.ctmAddresses!.chainTypeManager);
      expect(isRegistered).to.equal(true);
    });
  });
});

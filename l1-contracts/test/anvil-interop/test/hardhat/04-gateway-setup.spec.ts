import { expect } from "chai";
import { Contract, providers } from "ethers";
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

const GW_CHAIN_ID = 11;

describe("04 - Gateway Setup", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.ctmAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
  });

  describe("Gateway chain contracts", () => {
    let gwProvider: providers.JsonRpcProvider;

    before(() => {
      const gwChain = state.chains!.l2.find((c) => c.chainId === GW_CHAIN_ID);
      if (!gwChain) {
        throw new Error(`GW chain ${GW_CHAIN_ID} not found`);
      }
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

    it("has all interop chains registered on GW L2Bridgehub", async () => {
      const l2BhAbi = l2BridgehubAbi();
      const l2Bridgehub = new Contract(L2_BRIDGEHUB_ADDR, l2BhAbi, gwProvider);

      for (const chainId of [10, 11, 12, 13]) {
        const baseTokenAssetId = await l2Bridgehub.baseTokenAssetId(chainId);
        expect(baseTokenAssetId, `Chain ${chainId} should be registered on GW L2Bridgehub`).to.not.equal(
          "0x0000000000000000000000000000000000000000000000000000000000000000"
        );
      }
    });
  });

  describe("Gateway designation on L1", () => {
    let l1Provider: providers.JsonRpcProvider;

    before(() => {
      l1Provider = new providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
    });

    it("GW chain has diamond proxy on L1", async () => {
      const chainAddr = state.chainAddresses!.find((c) => c.chainId === GW_CHAIN_ID);
      expect(chainAddr, `GW chain ${GW_CHAIN_ID} not found in chainAddresses`).to.exist;
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

import { expect } from "chai";
import { Contract, providers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { l1BridgehubAbi } from "../../src/core/contracts";
import {
  L2_BRIDGEHUB_ADDR,
  L2_ASSET_ROUTER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
  L2_MESSAGE_ROOT_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  INTEROP_CENTER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_ASSET_TRACKER_ADDR,
  L2_MESSAGE_VERIFICATION_ADDR,
  GW_ASSET_TRACKER_ADDR,
} from "../../src/core/const";

describe("01 - Deployment Verification", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.ctmAddresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
  });

  describe("L1 contracts", () => {
    let l1Provider: providers.JsonRpcProvider;

    before(() => {
      l1Provider = new providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
    });

    it("has Bridgehub deployed with code", async () => {
      const code = await l1Provider.getCode(state.l1Addresses!.bridgehub);
      expect(code).to.not.equal("0x");
    });

    it("has L1AssetRouter (SharedBridge) deployed with code", async () => {
      const code = await l1Provider.getCode(state.l1Addresses!.l1SharedBridge);
      expect(code).to.not.equal("0x");
    });

    it("has L1NativeTokenVault deployed with code", async () => {
      const code = await l1Provider.getCode(state.l1Addresses!.l1NativeTokenVault);
      expect(code).to.not.equal("0x");
    });

    it("has L1AssetTracker deployed with code", async () => {
      const code = await l1Provider.getCode(state.l1Addresses!.l1AssetTracker);
      expect(code).to.not.equal("0x");
    });

    it("has CTM registered in Bridgehub", async () => {
      const bridgehubAbi = l1BridgehubAbi();
      const bridgehub = new Contract(state.l1Addresses!.bridgehub, bridgehubAbi, l1Provider);
      const isRegistered = await bridgehub.chainTypeManagerIsRegistered(state.ctmAddresses!.chainTypeManager);
      expect(isRegistered).to.equal(true);
    });
  });

  describe("L2 chain registration", () => {
    let l1Provider: providers.JsonRpcProvider;

    before(() => {
      l1Provider = new providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
    });

    for (const chainConfig of runner.getConfig().chains.filter((c) => !c.isL1)) {
      it(`chain ${chainConfig.chainId} (${chainConfig.role}) has diamond proxy on L1`, async () => {
        const chainAddr = state.chainAddresses!.find((c) => c.chainId === chainConfig.chainId);
        expect(chainAddr, `Chain ${chainConfig.chainId} not found in chainAddresses`).to.exist;
        const code = await l1Provider.getCode(chainAddr!.diamondProxy);
        expect(code).to.not.equal("0x");
      });
    }
  });

  describe("L2 system contracts", () => {
    const expectedContracts = [
      { addr: L2_BRIDGEHUB_ADDR, name: "L2Bridgehub" },
      { addr: L2_ASSET_ROUTER_ADDR, name: "L2AssetRouter" },
      { addr: L2_NATIVE_TOKEN_VAULT_ADDR, name: "L2NativeTokenVault" },
      { addr: L2_MESSAGE_ROOT_ADDR, name: "L2MessageRoot" },
      { addr: L2_CHAIN_ASSET_HANDLER_ADDR, name: "L2ChainAssetHandler" },
      { addr: INTEROP_CENTER_ADDR, name: "InteropCenter" },
      { addr: L2_INTEROP_HANDLER_ADDR, name: "InteropHandler" },
      { addr: L2_ASSET_TRACKER_ADDR, name: "L2AssetTracker" },
      { addr: L2_MESSAGE_VERIFICATION_ADDR, name: "L2MessageVerification" },
      { addr: GW_ASSET_TRACKER_ADDR, name: "GWAssetTracker" },
    ];

    const config = runner.getConfig();
    for (const chainConfig of config.chains.filter((c) => !c.isL1)) {
      describe(`chain ${chainConfig.chainId} (${chainConfig.role})`, () => {
        let l2Provider: providers.JsonRpcProvider;

        before(() => {
          const chain = state.chains!.l2.find((c) => c.chainId === chainConfig.chainId);
          if (!chain) {
            throw new Error(`L2 chain ${chainConfig.chainId} not found`);
          }
          l2Provider = new providers.JsonRpcProvider(chain.rpcUrl);
        });

        for (const contract of expectedContracts) {
          it(`has ${contract.name} at ${contract.addr}`, async () => {
            const code = await l2Provider.getCode(contract.addr);
            expect(code, `${contract.name} not deployed on chain ${chainConfig.chainId}`).to.not.equal("0x");
            expect(code).to.not.equal("0x0");
          });
        }
      });
    }
  });

  describe("Test tokens", () => {
    it("test tokens deployed on all L2 chains", () => {
      expect(state.testTokens).to.exist;
      for (const l2Chain of state.chains!.l2) {
        expect(state.testTokens![l2Chain.chainId], `Test token not deployed on chain ${l2Chain.chainId}`).to.be.a(
          "string"
        );
      }
    });

    const config = runner.getConfig();
    for (const chainConfig of config.chains.filter((c) => !c.isL1)) {
      it(`test token on chain ${chainConfig.chainId} (${chainConfig.role}) has code`, async () => {
        const tokenAddr = state.testTokens![chainConfig.chainId];
        if (!tokenAddr) {
          return; // Skip if token wasn't deployed (will be caught by prior test)
        }
        const chain = state.chains!.l2.find((c) => c.chainId === chainConfig.chainId);
        const provider = new providers.JsonRpcProvider(chain!.rpcUrl);
        const code = await provider.getCode(tokenAddr);
        expect(code).to.not.equal("0x");
      });
    }
  });
});

import { execFileSync } from "child_process";
import * as path from "path";
import { expect } from "chai";
import type { providers } from "ethers";
import { Contract, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getAbi } from "../../src/core/contracts";
import { createProvider } from "../../src/core/utils";
import { PREDEPLOY_SYSTEM_CONTRACTS } from "../../src/core/predeploys";

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
      l1Provider = createProvider(state.chains!.l1!.rpcUrl);
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

    it("has CTM registered in Bridgehub", async () => {
      const bridgehubAbi = getAbi("L1Bridgehub");
      const bridgehub = new Contract(state.l1Addresses!.bridgehub, bridgehubAbi, l1Provider);
      const isRegistered = await bridgehub.chainTypeManagerIsRegistered(state.ctmAddresses!.chainTypeManager);
      expect(isRegistered).to.equal(true);
    });
  });

  describe("L2 chain registration", () => {
    let l1Provider: providers.JsonRpcProvider;

    before(() => {
      l1Provider = createProvider(state.chains!.l1!.rpcUrl);
    });

    for (const chainConfig of runner.getConfig().chains.filter((c) => c.role !== "l1")) {
      it(`chain ${chainConfig.chainId} (${chainConfig.role}) has diamond proxy on L1`, async () => {
        const chainAddr = state.chainAddresses!.find((c) => c.chainId === chainConfig.chainId);
        expect(chainAddr, `Chain ${chainConfig.chainId} not found in chainAddresses`).to.exist;
        const code = await l1Provider.getCode(chainAddr!.diamondProxy);
        expect(code).to.not.equal("0x");
        const bridgehub = new Contract(state.l1Addresses!.bridgehub, getAbi("L1Bridgehub"), l1Provider);
        expect(await bridgehub.getZKChain(chainConfig.chainId)).to.equal(chainAddr!.diamondProxy);
        const diamond = new Contract(chainAddr!.diamondProxy, getAbi("IZKChain"), l1Provider);
        expect((await diamond.getChainId()).toNumber()).to.equal(chainConfig.chainId);
        expect(await diamond.getChainTypeManager()).to.equal(state.ctmAddresses!.chainTypeManager);
      });
    }
  });

  describe("L2 system contracts", () => {
    // The harness deliberately installs MockL2MessageVerification, MockL1MessengerHook,
    // MockMintBaseTokenHook and MockContractDeployer; compare them against their mock artifacts.
    const expectedContracts = PREDEPLOY_SYSTEM_CONTRACTS;
    const expectedBytecodes = new Map<string, string>();

    before(() => {
      // Snapshots use the metadata-free anvil-interop profile. Build matching references in
      // isolated output/cache directories so coverage's default-profile artifacts stay intact.
      const root = path.resolve(__dirname, "../../../..");
      const output = path.join(
        root,
        "test/anvil-interop/outputs",
        `predeploy-identity${process.env.ANVIL_INTEROP_RUN_SUFFIX || ""}`
      );
      const buildArgs = ["--out", path.join(output, "out"), "--cache-path", path.join(output, "cache")];
      const options = {
        cwd: root,
        env: { ...process.env, FOUNDRY_PROFILE: "anvil-interop" },
        encoding: "utf8" as const,
        maxBuffer: 32 * 1024 * 1024,
      };
      execFileSync("forge", ["build", "--skip", "test", "--skip", "script", ...buildArgs], options);
      const artifactNames = [...expectedContracts.map(({ contractName }) => contractName), "L2ChainAssetHandlerDev"];
      for (const contractName of artifactNames) {
        expectedBytecodes.set(
          contractName,
          execFileSync("forge", ["inspect", contractName, "deployedBytecode", ...buildArgs], options).trim()
        );
      }
    });

    const config = runner.getConfig();
    for (const chainConfig of config.chains.filter((c) => c.role !== "l1")) {
      describe(`chain ${chainConfig.chainId} (${chainConfig.role})`, () => {
        let l2Provider: providers.JsonRpcProvider;

        before(() => {
          const chain = state.chains!.l2.find((c) => c.chainId === chainConfig.chainId);
          if (!chain) {
            throw new Error(`L2 chain ${chainConfig.chainId} not found`);
          }
          l2Provider = createProvider(chain.rpcUrl);
        });

        for (const contract of expectedContracts) {
          it(`has ${contract.contractName} at ${contract.address}`, async () => {
            const code = await l2Provider.getCode(contract.address);
            // Gateway setup deliberately replaces this predeploy to enable test migrations.
            const artifactName =
              chainConfig.role === "gateway" && contract.contractName === "L2ChainAssetHandler"
                ? "L2ChainAssetHandlerDev"
                : contract.contractName;
            const expectedCode = expectedBytecodes.get(artifactName)!;
            expect(expectedCode, `${contract.contractName} runtime artifact must exist`).to.not.equal("0x");
            expect(
              ethers.utils.keccak256(code),
              `${contract.contractName} runtime identity on chain ${chainConfig.chainId}`
            ).to.equal(ethers.utils.keccak256(expectedCode));
          });
        }
      });
    }
  });

  describe("Test tokens", () => {
    it("test tokens deployed on all L2 chains", () => {
      expect(state.testTokens).to.exist;
      for (const l2Chain of state.chains!.l2) {
        expect(
          ethers.utils.isAddress(state.testTokens![l2Chain.chainId]),
          `Test token address on chain ${l2Chain.chainId}`
        ).to.equal(true);
      }
    });

    const config = runner.getConfig();
    for (const chainConfig of config.chains.filter((c) => c.role !== "l1")) {
      it(`test token on chain ${chainConfig.chainId} (${chainConfig.role}) has code`, async () => {
        const tokenAddr = state.testTokens![chainConfig.chainId];
        expect(tokenAddr, `Test token required on chain ${chainConfig.chainId}`).to.match(/^0x[0-9a-fA-F]{40}$/);
        const chain = state.chains!.l2.find((c) => c.chainId === chainConfig.chainId);
        const provider = createProvider(chain!.rpcUrl);
        const code = await provider.getCode(tokenAddr);
        expect(code).to.not.equal("0x");
      });
    }
  });
});

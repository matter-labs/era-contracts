import { execFileSync } from "child_process";
import * as fs from "fs";
import * as path from "path";
import { expect } from "chai";
import type { providers } from "ethers";
import { Contract, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { getAbi, getBytecode, getSolidityContractName, getSoliditySourceFileName } from "../../src/core/contracts";
import type { ContractName } from "../../src/core/contracts";
import { createProvider } from "../../src/core/utils";
import { PREDEPLOY_SYSTEM_CONTRACTS } from "../../src/core/predeploys";
import { TEST_TOKEN_DECIMALS, TEST_TOKEN_MINT_AMOUNT_UNITS } from "../../src/core/const";

/** The Solidity source under `contractsDir` that defines each contract, found by its file name, which must be unique. */
function findSoliditySources(contractsDir: string, contractNames: readonly ContractName[]): string[] {
  const pathsByFileName = new Map<string, string[]>();
  const walk = (dir: string): void => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const entryPath = path.join(dir, entry.name);
      if (entry.isDirectory()) {
        walk(entryPath);
      } else {
        pathsByFileName.set(entry.name, [...(pathsByFileName.get(entry.name) ?? []), entryPath]);
      }
    }
  };
  walk(contractsDir);
  return contractNames.map((contractName) => {
    const fileName = getSoliditySourceFileName(contractName);
    const matches = pathsByFileName.get(fileName) ?? [];
    if (matches.length !== 1) {
      throw new Error(`Expected exactly one ${fileName} under ${contractsDir}, found ${matches.length}`);
    }
    return matches[0];
  });
}

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

    it("has Bridgehub wired to L1AssetRouter, MessageRoot, CTMDeploymentTracker and ChainRegistrationSender", async () => {
      const l1 = state.l1Addresses!;
      const bridgehub = new Contract(l1.bridgehub, getAbi("L1Bridgehub"), l1Provider);
      expect(await bridgehub.assetRouter(), "assetRouter").to.equal(l1.l1SharedBridge);
      expect(await bridgehub.messageRoot(), "messageRoot").to.equal(l1.messageRoot);
      expect(await bridgehub.l1CtmDeployer(), "l1CtmDeployer").to.equal(l1.ctmDeploymentTracker);
      expect(await bridgehub.chainRegistrationSender(), "chainRegistrationSender").to.equal(l1.chainRegistrationSender);
    });

    it("has L1AssetRouter (SharedBridge) wired to Bridgehub, L1Nullifier and L1NativeTokenVault", async () => {
      const l1 = state.l1Addresses!;
      const assetRouter = new Contract(l1.l1SharedBridge, getAbi("L1AssetRouter"), l1Provider);
      expect(await assetRouter.BRIDGE_HUB(), "BRIDGE_HUB").to.equal(l1.bridgehub);
      expect(await assetRouter.L1_NULLIFIER(), "L1_NULLIFIER").to.equal(l1.l1NullifierProxy);
      expect(await assetRouter.nativeTokenVault(), "nativeTokenVault").to.equal(l1.l1NativeTokenVault);
    });

    it("has L1NativeTokenVault wired to L1AssetRouter and L1Nullifier", async () => {
      const l1 = state.l1Addresses!;
      const ntv = new Contract(l1.l1NativeTokenVault, getAbi("L1NativeTokenVault"), l1Provider);
      expect(await ntv.ASSET_ROUTER(), "ASSET_ROUTER").to.equal(l1.l1SharedBridge);
      expect(await ntv.L1_NULLIFIER(), "L1_NULLIFIER").to.equal(l1.l1NullifierProxy);
    });

    it("has L1Nullifier wired to Bridgehub, MessageRoot, L1AssetRouter and L1NativeTokenVault", async () => {
      const l1 = state.l1Addresses!;
      const nullifier = new Contract(l1.l1NullifierProxy, getAbi("L1Nullifier"), l1Provider);
      expect(await nullifier.BRIDGE_HUB(), "BRIDGE_HUB").to.equal(l1.bridgehub);
      expect(await nullifier.MESSAGE_ROOT(), "MESSAGE_ROOT").to.equal(l1.messageRoot);
      expect(await nullifier.l1AssetRouter(), "l1AssetRouter").to.equal(l1.l1SharedBridge);
      expect(await nullifier.l1NativeTokenVault(), "l1NativeTokenVault").to.equal(l1.l1NativeTokenVault);
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
      it(`chain ${chainConfig.chainId} (${chainConfig.role}) is registered on L1 with its chain ID and CTM`, async () => {
        const chainAddr = state.chainAddresses!.find((c) => c.chainId === chainConfig.chainId);
        expect(chainAddr, `Chain ${chainConfig.chainId} not found in chainAddresses`).to.exist;
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
    const artifactNames: ContractName[] = [
      ...expectedContracts.map(({ contractName }) => contractName),
      "L2ChainAssetHandlerDev",
    ];
    // Read from the state the run that started the chains wrote, so reruns against kept chains agree.
    const fromSnapshots = runner.loadState().startedFrom !== "freshDeploy";
    const reference = fromSnapshots ? "anvil-interop profile build" : "installed out/ artifact";

    before(() => {
      if (!fromSnapshots) {
        // A fresh deployment installs every predeploy from out/, whatever profile built it.
        for (const contractName of artifactNames) {
          expectedBytecodes.set(contractName, getBytecode(contractName));
        }
        return;
      }
      // Snapshots use the metadata-free anvil-interop profile. Build matching references in
      // isolated output/cache directories so coverage's default-profile artifacts stay intact.
      const root = path.resolve(__dirname, "../../../..");
      // Compile only the predeploys' sources and their imports, not the whole project.
      const sources = findSoliditySources(path.join(root, "contracts"), artifactNames);
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
      execFileSync("forge", ["build", ...sources, ...buildArgs], options);
      for (const contractName of artifactNames) {
        const solidityName = getSolidityContractName(contractName);
        expectedBytecodes.set(
          contractName,
          execFileSync("forge", ["inspect", solidityName, "deployedBytecode", ...buildArgs], options).trim()
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
          it(`has ${contract.contractName} at ${contract.address} matching its ${reference}`, async () => {
            const code = await l2Provider.getCode(contract.address);
            // Gateway setup deliberately replaces this predeploy to enable test migrations.
            const artifactName =
              chainConfig.role === "gateway" && contract.contractName === "L2ChainAssetHandler"
                ? "L2ChainAssetHandlerDev"
                : contract.contractName;
            const expectedCode = expectedBytecodes.get(artifactName)!;
            expect(expectedCode, `${artifactName} ${reference} must exist`).to.not.equal("0x");
            expect(
              ethers.utils.keccak256(code),
              `${contract.contractName} runtime on chain ${chainConfig.chainId} vs its ${reference}`
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
      it(`test token on chain ${chainConfig.chainId} (${chainConfig.role}) has the deployed decimals and supply`, async () => {
        const tokenAddr = state.testTokens![chainConfig.chainId];
        expect(tokenAddr, `Test token required on chain ${chainConfig.chainId}`).to.match(/^0x[0-9a-fA-F]{40}$/);
        const chain = state.chains!.l2.find((c) => c.chainId === chainConfig.chainId);
        const token = new Contract(tokenAddr, getAbi("TestnetERC20Token"), createProvider(chain!.rpcUrl));
        expect(await token.decimals(), "decimals").to.equal(TEST_TOKEN_DECIMALS);
        // Not the deployer's balance, which the specs move, also on kept chains. Bridging a chain-native token
        // out escrows it in the L2NativeTokenVault, so its supply stays what setup minted.
        expect((await token.totalSupply()).toString(), "totalSupply").to.equal(
          ethers.utils.parseUnits(TEST_TOKEN_MINT_AMOUNT_UNITS, TEST_TOKEN_DECIMALS).toString()
        );
      });
    }
  });
});

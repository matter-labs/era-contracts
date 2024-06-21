// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { web3Url, web3Provider } from "./utils";
import { ethers } from "ethers";
import { Provider, utils } from "zksync-ethers";

import type { Deployer } from "../src.ts/deploy";
import { IERC20Factory } from "../typechain/IERC20Factory";

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-shared-bridge-era").description("upgrade shared bridge for era diamond proxy");

  program
    .command("get-confirmed-tokens")
    .description("Returns the list of tokens that are registered on the bridge and should be migrated")
    .option("--use-l1")
    .option("--start-from-block <startFromBlock>")
    .action(async (cmd) => {
      const l2Provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
      const l1Provider = new ethers.providers.JsonRpcProvider(web3Url());

      let confirmedFromAPI;

      if (cmd.useL1) {
        const block = cmd.startFromBlock;
        if (!block) {
          throw new Error("For L1 the starting block should be provided");
        }

        console.log("Fetching confirmed tokens from the L1");
        console.log("This will take a long time");

        const bridge = (await l2Provider.getDefaultBridgeAddresses()).erc20L1;
        console.log("Using L1 ERC20 bridge ", bridge);

        const confirmedFromL1 = await loadAllConfirmedTokensFromL1(l1Provider, bridge, +block);
        console.log(JSON.stringify(confirmedFromL1, null, 2));
      } else {
        console.log("Fetching confirmed tokens from the L2 API...");
        confirmedFromAPI = await loadAllConfirmedTokensFromAPI(l2Provider);

        console.log(JSON.stringify(confirmedFromAPI, null, 2));
      }
    });

  program
    .command("merge-confirmed-tokens")
    .description("Merges two lists of confirmed tokens")
    .option("--from-l1 <tokensFromL1>")
    .option("--from-l2 <tokensFromL2>")
    .action(async (cmd) => {
      const l2Provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
      const bridge = (await l2Provider.getDefaultBridgeAddresses()).erc20L1;
      console.log("Using L1 ERC20 bridge ", bridge);

      const allTokens = {};
      const tokensFromL1: string[] = JSON.parse(cmd.fromL1).map((token) => token.toLowerCase());
      const tokensFromL2: string[] = JSON.parse(cmd.fromL2).map((token) => token.toLowerCase());

      tokensFromL1.forEach((token) => (allTokens[token] = true));
      tokensFromL2.forEach((token) => (allTokens[token] = true));

      const erc20Abi = ["function balanceOf(address) view returns (uint256)"];

      const result = [];

      const l1Provider = new ethers.providers.JsonRpcProvider(web3Url());
      for (const token of Object.keys(allTokens)) {
        const contract = new ethers.Contract(token, erc20Abi, l1Provider);
        const balanceL1 = await contract.balanceOf(bridge);
        if (balanceL1.gt(0)) {
          console.log("Token ", token, " has balance in the bridge ", balanceL1.toString());
          result.push(token);
        }
      }

      console.log(JSON.stringify(result, null, 2));
    });

  program
    .command("prepare-migration-calldata")
    .description("Prepare the calldata to be signed by the governance to migrate the funds from the legacy bridge")
    .option("--tokens-list <tokensList>")
    .option("--gas-per-token <gasPerToken>")
    .option("--tokens-per-signature <tokensPerSignature>")
    .option("--shared-bridge-addr <sharedBridgeAddr>")
    .option("--legacy-bridge-addr <legacyBridgeAddr>")
    .option("--era-chain-addr <eraChainAddress>")
    .option("--era-chain-id <eraChainId>")
    .option("--delay <delay>")

    .action(async (cmd) => {
      const allTokens: string[] = JSON.parse(cmd.tokensList);
      // Appending the ETH token to be migrated
      allTokens.push("0x0000000000000000000000000000000000000001");

      const tokensPerSignature = +cmd.tokensPerSignature;

      const scheduleCalldatas = [];
      const executeCalldatas = [];

      for (let i = 0; i < allTokens.length; i += tokensPerSignature) {
        const tokens = allTokens.slice(i, Math.min(i + tokensPerSignature, allTokens.length));
        const { scheduleCalldata, executeCalldata } = await prepareGovernanceTokenMigrationCall(
          tokens,
          cmd.sharedBridgeAddr,
          cmd.legacyBridgeAddr,
          cmd.eraChainAddr,
          cmd.eraChainId,
          +cmd.gasPerToken,
          +cmd.delay
        );

        scheduleCalldatas.push(scheduleCalldata);
        executeCalldatas.push(executeCalldata);
      }

      console.log("Schedule operations to sign: ");
      scheduleCalldatas.forEach((calldata) => console.log(calldata + "\n"));

      console.log("Execute operations to sign: ");
      executeCalldatas.forEach((calldata) => console.log(calldata + "\n"));
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err) => {
    console.error("Error:", err);
    process.exit(1);
  });

async function loadAllConfirmedTokensFromAPI(l2Provider: Provider) {
  const limit = 50;
  const result = [];
  let offset = 0;

  // eslint-disable-next-line no-constant-condition
  while (true) {
    const tokens = await l2Provider.send("zks_getConfirmedTokens", [offset, limit]);
    if (!tokens.length) {
      return result;
    }

    tokens.forEach((token) => result.push(token.l1Address));
    offset += limit;
  }
}

async function loadAllConfirmedTokensFromL1(
  l1Provider: ethers.providers.JsonRpcProvider,
  bridgeAddress: string,
  startBlock: number
) {
  const blocksRange = 50000;
  const endBlock = await l1Provider.getBlockNumber();
  const abi = (await hardhat.artifacts.readArtifact("IL1ERC20Bridge")).abi;
  const contract = new ethers.Contract(bridgeAddress, abi, l1Provider);
  const filter = contract.filters.DepositInitiated();

  const tokens = {};

  while (startBlock <= endBlock) {
    console.log("Querying blocks ", startBlock, " - ", Math.min(startBlock + blocksRange, endBlock));
    const logs = await l1Provider.getLogs({
      ...filter,
      fromBlock: startBlock,
      toBlock: Math.min(startBlock + blocksRange, endBlock),
    });
    const deposits = logs.map((log) => contract.interface.parseLog(log));
    deposits.forEach((dep) => {
      if (!tokens[dep.args.l1Token]) {
        console.log(dep.args.l1Token, " found!");
      }
      tokens[dep.args.l1Token] = true;
    });

    startBlock += blocksRange;
  }

  return Object.keys(tokens);
}

async function prepareGovernanceTokenMigrationCall(
  tokens: string[],
  l1SharedBridgeAddr: string,
  l1LegacyBridgeAddr: string,
  eraChainAddress: string,
  eraChainId: number,
  gasPerToken: number,
  delay: number
) {
  const governanceAbi = new ethers.utils.Interface((await hardhat.artifacts.readArtifact("IGovernance")).abi);
  const sharedBridgeAbi = new ethers.utils.Interface((await hardhat.artifacts.readArtifact("L1SharedBridge")).abi);
  const calls = tokens.map((token) => {
    const target = token == utils.ETH_ADDRESS_IN_CONTRACTS ? eraChainAddress : l1LegacyBridgeAddr;

    return {
      target: l1SharedBridgeAddr,
      value: 0,
      data: sharedBridgeAbi.encodeFunctionData("safeTransferFundsFromLegacy", [token, target, eraChainId, gasPerToken]),
    };
  });
  const governanceOp = {
    calls,
    predecessor: ethers.constants.HashZero,
    salt: ethers.constants.HashZero,
  };

  const scheduleCalldata = governanceAbi.encodeFunctionData("scheduleTransparent", [governanceOp, delay]);
  const executeCalldata = governanceAbi.encodeFunctionData("execute", [governanceOp]);

  return {
    scheduleCalldata,
    executeCalldata,
  };
}

const provider = web3Provider();

/// used together with anvil for local fork tests. Not used at the moment, will be used for next token migration.
// https://www.notion.so/matterlabs/Mainnet-shared-bridge-token-fork-test-aac05561dda64fb4ad38c40d2f479378?pvs=4
export async function transferTokensOnForkedNetwork(deployer: Deployer) {
  // the list of tokens that need to be migrated, use output from `get-confirmed-tokens` command
  const tokenList = ["0x5A520e593F89c908cd2bc27D928bc75913C55C42"];
  for (const tokenAddress of tokenList) {
    const erc20contract = IERC20Factory.connect(tokenAddress, provider);
    console.log(`Migrating token ${tokenAddress}`);
    console.log(
      `Balance before: ${await erc20contract.balanceOf(deployer.addresses.Bridges.ERC20BridgeProxy)}, ${await erc20contract.balanceOf(deployer.addresses.Bridges.SharedBridgeProxy)}`
    );
    await transferTokens(deployer, tokenAddress);
    console.log(
      `Balance after: ${await erc20contract.balanceOf(deployer.addresses.Bridges.ERC20BridgeProxy)}, ${await erc20contract.balanceOf(deployer.addresses.Bridges.SharedBridgeProxy)}`
    );
  }
  for (const tokenAddress of tokenList) {
    const erc20contract = IERC20Factory.connect(tokenAddress, provider);
    if (!(await erc20contract.balanceOf(deployer.addresses.Bridges.ERC20BridgeProxy)).eq(0)) {
      console.log(`Failed to transfer all tokens ${tokenAddress}`);
    }
  }
}

/// This is used to transfer tokens from the sharedBridge.
/// We're keeping this as we will have another migration of tokens, but it is not used atm.
export async function transferTokens(deployer: Deployer, token: string) {
  const eraChainId = "324";
  const sharedBridge = deployer.defaultSharedBridge(deployer.deployWallet);
  const tx = await sharedBridge.safeTransferFundsFromLegacy(
    token,
    deployer.addresses.Bridges.ERC20BridgeProxy,
    eraChainId,
    "1000000",
    { gasLimit: 25_000_000 }
  );
  await tx.wait();
  console.log("Receipt", tx.hash);
}

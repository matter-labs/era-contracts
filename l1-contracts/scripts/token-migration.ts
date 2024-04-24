// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { Wallet, ethers } from "ethers";
import { Deployer } from "../src.ts/deploy";
import { formatUnits, parseUnits, Interface } from "ethers/lib/utils";
import { web3Provider, GAS_MULTIPLIER, web3Url } from "./utils";
import { deployedAddressesFromEnv } from "../src.ts/deploy-utils";
import { ethTestConfig, getAddressFromEnv } from "../src.ts/utils";
import { hashL2Bytecode } from "../../l2-contracts/src/utils";
import { Provider } from "zksync-web3";
import beaconProxy = require("../../l2-contracts/artifacts-zk/@openzeppelin/contracts/proxy/beacon/BeaconProxy.sol/BeaconProxy.json");
import { config } from "chai";

const provider = web3Provider();

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-shared-bridge-era").description("upgrade shared bridge for era diamond proxy");

  program
    .command('get-confirmed-tokens')
    .description('Returns the list of tokens that are registered on the bridge and should be migrated')
    .option("--use-l1")
    .option("--start-from-block <startFromBlock>")
    .action(async (cmd) => {
        const l2Provider = new Provider(process.env.API_WEB3_JSON_RPC_HTTP_URL);
        const l1Provider = new ethers.providers.JsonRpcProvider(web3Url());

        let confirmedFromAPI;

        if(cmd.useL1) {
            const block = cmd.startFromBlock;
            if(!block) {
                throw new Error('For L1 the starting block should be provided');
            }

            console.log('Fetching confirmed tokens from the L1');
            console.log('This will take a long time');

            const bridge =  (await l2Provider.getDefaultBridgeAddresses()).erc20L1;
            console.log('Using L1 ERC20 bridge ', bridge);

            const confirmedFromL1 = await loadAllConfirmedTokensFromL1(l1Provider, bridge, +block);
            console.log(JSON.stringify(confirmedFromL1, null, 2));
        } else {
            console.log('Fetching confirmed tokens from the L2 API...');
            confirmedFromAPI = await loadAllConfirmedTokensFromAPI(l2Provider);
    
            console.log(JSON.stringify(confirmedFromAPI, null, 2))    
        }
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

    while(true) {
        const tokens = await l2Provider.getConfirmedTokens(offset, limit);
        if(tokens.length === 0) {
            return result;
        }

        tokens.forEach((token) => result.push(token.l1Address));
        offset += limit;1
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
    const contract = new ethers.Contract(
        bridgeAddress,
        abi,
        l1Provider
    );
    const filter = contract.filters.DepositInitiated();

    const tokens = {};

    while(true) {
        console.log('Querying blocks ', startBlock, ' - ', Math.min(startBlock + blocksRange, endBlock));
        const logs = await l1Provider.getLogs({
            ...filter,
            fromBlock: startBlock,
            toBlock: Math.min(startBlock + blocksRange, endBlock),
        });
        const deposits = logs.map(log => contract.interface.parseLog(log));
        deposits.forEach(dep => {
            if(!tokens[dep.args.l1Token]) {
                console.log(dep.args.l1Token, ' found!');
            }
            tokens[dep.args.l1Token] = true
        });

        startBlock += blocksRange;
        if(startBlock > endBlock) {
            break;
        }
    }

    return Object.keys(tokens);
}

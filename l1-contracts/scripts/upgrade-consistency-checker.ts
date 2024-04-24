/// This is the script to double check the consistency of the upgrade
/// It is yet to be refactored.

// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import { Command } from "commander";
import { web3Url } from "./utils";
import { ethers } from "ethers";
import { Provider, utils } from "zksync-ethers";

// List the contracts that should become the upgrade targets
const genesisUpgrade = '0xc6aB8b3b93f3E47fb4163eB9Dc7A61E1a5D86369';
const validatorTimelock = '0xDBCCB9acA2D3cdFdC42718FDa5305643e5346eae';
const upgradeHyperchains = '0x3da9052db9DAe40FA48b5dF953557E2800B53953';
const proxyAdmin = '0x778A2ccbf5BC56c5c8dFb91e148727432510ED31';
const bridgeHubImpl = '0xF9D2E98Ed518eC6Daac0579a9707d83da55D5f89';
const bridgeHub = '0xE26CbC42932414F8088dA36707a422799232DCAE';

const executorFacet = '0x1a451d9bFBd176321966e9bc540596Ca9d39B4B1';
const mailboxFacet = '0x93B36f4c665969b71dd101DC7BdAD7cA2598b321';
const gettersFacet = '0x345c6ca2F3E08445614f4299001418F125AD330a';
const adminFacet = '0x342a09385E9BAD4AD32a6220765A6c333552e565';

const verify = '0xaD2D9B8a8d52a7Aa700738979961a3305B284255';

const stmImpl = '0x8eff8A1314D9A8206A574e61929746E29B9f3436';
const stm = '0x741224120ae4Cc8dac00B6E62f62C3e8de85816E';

const erc20Impl = '0x741224120ae4Cc8dac00B6E62f62C3e8de85816E';
const sharedBridgeImpl = '0xe1bF4bd1e684DF322608a02CE915EF2D5a632b3A';
const sharedBridgeProxy = '0xDe67Fea076e0230EeeA3223bBE8FA6823fca0E89';

const l1Provider = new ethers.providers.JsonRpcProvider(web3Url());

async function checkIdenticalBytecode(addr: string, contract: string) {
  const correctCode = (await hardhat.artifacts.readArtifact(contract)).deployedBytecode;
  const currentCode = await l1Provider.getCode(addr);

  if (ethers.utils.keccak256(currentCode) == ethers.utils.keccak256(correctCode)) {
    console.log(contract, 'bytecode is correct');
  } else {
    throw new Error(contract + ' bytecode is not correct');
  }
}

async function main() {
  const program = new Command();

  program.version("0.1.0").name("upgrade-consistency-checker").description("upgrade shared bridge for era diamond proxy");

  program
    .action(async (cmd) => {
      await checkIdenticalBytecode(genesisUpgrade, 'GenesisUpgrade');
      await checkIdenticalBytecode(upgradeHyperchains, 'UpgradeHyperchains');
      await checkIdenticalBytecode(proxyAdmin, 'ProxyAdmin');
      await checkIdenticalBytecode(executorFacet, "ExecutorFacet");
      await checkIdenticalBytecode(gettersFacet, "GettersFacet");
      await checkIdenticalBytecode(adminFacet, "AdminFacet");
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

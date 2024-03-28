import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";
import "@nomicfoundation/hardhat-chai-matchers";
import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-solpp";
import "hardhat-typechain";
import { task } from "hardhat/config";
import { TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS } from "hardhat/builtin-tasks/task-names";

// If no network is specified, use the default config
if (!process.env.CHAIN_ETH_NETWORK) {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require("dotenv").config();
}

const prodConfig = {
  ERA_CHAIN_ID: 324,
};
const testnetConfig = {
  ERA_CHAIN_ID: 300,
  ERA_WETH_ADDRESS: "address(0)",
};
const hardhatConfig = {
  ERA_CHAIN_ID: 9,
  ERA_WETH_ADDRESS: "address(0)",
};
const localConfig = {
  ERA_CHAIN_ID: 9,
  ERA_WETH_ADDRESS: "address(0)",
};

const contractDefs = {
  sepolia: testnetConfig,
  rinkeby: testnetConfig,
  ropsten: testnetConfig,
  goerli: testnetConfig,
  mainnet: prodConfig,
  hardhat: hardhatConfig,
  localhost: localConfig,
};

export default {
  zksolc: {
    version: "1.3.18",
    compilerSource: "binary",
    settings: {
      isSystem: true,
    },
  },
  solidity: {
    version: "0.8.20",
  },
  solpp: {
    defs: (() => {
      const defs = contractDefs[process.env.CHAIN_ETH_NETWORK];

      return {
        ...defs,
      };
    })(),
  },
  defaultNetwork: "localhost",
  networks: {
    localhost: {
      // era-test-node default url
      url: "http://127.0.0.1:8011",
      ethNetwork: null,
      zksync: true,
    },
    zkSyncTestnet: {
      url: "https://zksync2-testnet.zksync.dev",
      ethNetwork: "goerli",
      zksync: true,
      // contract verification endpoint
      verifyURL: "https://zksync2-testnet-explorer.zksync.dev/contract_verification",
    },
    zkSyncTestnetSepolia: {
      url: "https://sepolia.era.zksync.dev",
      ethNetwork: "sepolia",
      zksync: true,
      // contract verification endpoint
      verifyURL: "https://explorer.sepolia.era.zksync.dev/contract_verification",
    },
    zksyncMainnet: {
      url: "https://mainnet.era.zksync.io",
      ethNetwork: "mainnet",
      zksync: true,
      // contract verification endpoint
      verifyURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
    },
  },
};

task("solpp", "Preprocess Solidity source files").setAction(async (_, hre) =>
  hre.run(TASK_COMPILE_SOLIDITY_GET_SOURCE_PATHS)
);

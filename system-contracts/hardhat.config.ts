import "@matterlabs/hardhat-zksync-chai-matchers";
import "@matterlabs/hardhat-zksync-node";
import "@matterlabs/hardhat-zksync-solc";
import "@nomiclabs/hardhat-ethers";
import "hardhat-typechain";
import "@matterlabs/hardhat-zksync-verify";
import "@nomicfoundation/hardhat-verify";

export default {
  zksolc: {
    version: "1.3.18",
    compilerSource: "binary",
    settings: {
      isSystem: true,
    },
  },
  zkSyncDeploy: {
    zkSyncNetwork: "http://localhost:3050",
    ethNetwork: "http://localhost:8545",
  },
  solidity: {
    version: "0.8.20",
    settings: {
      optimizer: {
        enabled: true,
        runs: 9999999,
      },
      outputSelection: {
        "*": {
          "*": ["storageLayout"],
        },
      },
    },
  },
  networks: {
    hardhat: {
      zksync: true,
    },
    zkSyncTestNode: {
      url: "http://127.0.0.1:8011",
      ethNetwork: "",
      zksync: true,
    },
    zkSyncMainnet: {
      url: "https://mainnet.era.zksync.io", // The testnet RPC URL of zkSync Era network.
      ethNetwork: "mainnet",
      zksync: true,
      verifyURL: 'https://zksync2-mainnet-explorer.zksync.io/contract_verification'
    }
  },
  etherscan: {
    // Your API key for Etherscan
    // Obtain one at https://etherscan.io/
    apiKey: "ZWB4QWD7U76KNF72P7P5TK1958K85JBBXN"
  },
  paths: {
    sources: "./contracts-preprocessed",
  },
};

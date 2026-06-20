import "@matterlabs/hardhat-zksync-chai-matchers";
import "@matterlabs/hardhat-zksync-node";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";
import "@nomiclabs/hardhat-ethers";
import "hardhat-typechain";

export default {
  zksolc: {
    version: "1.5.0",
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
      ethNetwork: "localhost",
      zksync: true,
    },
    zkSyncTestnet: {
      url: "https://sepolia.era.zksync.dev",
      ethNetwork: "sepolia",
      zksync: true,
      // contract verification endpoint
      verifyURL: "https://explorer.sepolia.era.zksync.dev/contract_verification",
    },
    zkSyncMainnet: {
      url: "https://mainnet.era.zksync.io",
      ethNetwork: "mainnet",
      zksync: true,
      // contract verification endpoint
      verifyURL: "https://zksync2-mainnet-explorer.zksync.io/contract_verification",
    },
  },
  paths: {
    sources: "./contracts",
  },
};

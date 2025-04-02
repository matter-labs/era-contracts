import "@matterlabs/hardhat-zksync-chai-matchers";
import "@matterlabs/hardhat-zksync-node";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";
import "@nomiclabs/hardhat-ethers";
import "hardhat-typechain";

export default {
  zksolc: {
    version: "1.5.11",
    compilerSource: "binary",
    settings: {
      enableEraVMExtensions: true,
      suppressedErrors: ["sendtransfer"],
    },
  },
  zkSyncDeploy: {
    zkSyncNetwork: "http://localhost:3050",
    ethNetwork: "http://localhost:8545",
  },
  solidity: {
    version: "0.8.28",
    eraVersion: "1.5.11",
    settings: {
      evmVersion: "cancun",
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
    mainnet: {
      url: "https://mainnet.era.zksync.io",
      ethNetwork: "mainnet",
      zksync: true,
      verifyURL: "https://mainnet.zksync.io/contract_verification",
    },
    sepolia: {
      url: "https://sepolia.era.zksync.dev",
      ethNetwork: "sepolia",
      zksync: true,
      verifyURL: "https://sepolia.zksync.io/contract_verification",
    },
    zkSyncTestNode: {
      url: "http://127.0.0.1:8011",
      ethNetwork: "localhost",
      zksync: true,
    },
    stage: {
      url: "https://z2-dev-api.zksync.dev/",
      ethNetwork: "sepolia",
      zksync: true,
    },
  },
  paths: {
    sources: "./contracts-preprocessed",
  },
};

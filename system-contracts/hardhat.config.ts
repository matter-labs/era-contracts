import "@matterlabs/hardhat-zksync-chai-matchers";
import "@matterlabs/hardhat-zksync-node";
import "@matterlabs/hardhat-zksync-solc";
import "@nomiclabs/hardhat-ethers";
import "hardhat-typechain";

import { COMPILER_PATH } from "./scripts/constants";

export default {
  zksolc: {
    compilerSource: "binary",
    // version: 'zksolc-macosx-arm64-vprerelease-0640c18-test-zkvm-v1.5.0',
    settings: {
      compilerPath: COMPILER_PATH,
      isSystem: true,
    },
  },
  zkSyncDeploy: {
    zkSyncNetwork: process.env.TESTNET2,
    ethNetwork: process.env.INFURA,
  },
  solidity: {
    version: "0.8.24",
    settings: {
      evmVersion: 'cancun',
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
  },
  paths: {
    sources: "./contracts-preprocessed",
  },
};

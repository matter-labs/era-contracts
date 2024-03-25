import "@nomiclabs/hardhat-ethers";
import "@nomiclabs/hardhat-etherscan";
import "@nomiclabs/hardhat-waffle";
import "hardhat-contract-sizer";
import "hardhat-gas-reporter";
import "hardhat-typechain";
import "solidity-coverage";

// If no network is specified, use the default config
if (!process.env.CHAIN_ETH_NETWORK) {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require("dotenv").config();
}

export default {
  defaultNetwork: "env",
  solidity: {
    version: "0.8.24",
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
      evmVersion: "cancun",
    },
  },
  contractSizer: {
    runOnCompile: false,
    except: ["dev-contracts", "zksync/libraries", "common/libraries"],
  },
  paths: {
    sources: "./contracts",
  },
  networks: {
    env: {
      url: process.env.ETH_CLIENT_WEB3_URL?.split(",")[0],
    },
    hardhat: {
      allowUnlimitedContractSize: false,
      forking: {
        url: "https://eth-goerli.g.alchemy.com/v2/" + process.env.ALCHEMY_KEY,
        enabled: process.env.TEST_CONTRACTS_FORK === "1",
      },
    },
  },
  etherscan: {
    apiKey: process.env.MISC_ETHERSCAN_API_KEY,
  },
  gasReporter: {
    enabled: true,
  },
};

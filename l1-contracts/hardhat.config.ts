import "@nomiclabs/hardhat-ethers";

// If no network is specified, use the default config
if (!process.env.CHAIN_ETH_NETWORK) {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  require("dotenv").config();
}

const DEFAULT_ETH_NETWORK = "http://127.0.0.1:8545";

// Hardhat here exists only as the mocha runner for the anvil-interop suite
// (`test:hardhat:interop` spawns `hardhat test --network hardhat --no-compile`);
// contracts are compiled with Foundry, never through this config.
export default {
  defaultNetwork: "env",
  solidity: {
    version: "0.8.28",
    settings: {
      optimizer: {
        enabled: true,
        runs: 20000,
      },
      evmVersion: "cancun",
    },
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
    },
    localL1: {
      url: DEFAULT_ETH_NETWORK,
    },
  },
};

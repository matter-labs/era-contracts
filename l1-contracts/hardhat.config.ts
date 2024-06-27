import "@matterlabs/hardhat-zksync-solc";
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

const COMPILER_VERSION = "1.5.0";
const PRE_RELEASE_VERSION = "prerelease-a167aa3-code4rena";
function getZksolcUrl(): string {
  // @ts-ignore
  const platform = { darwin: "macosx", linux: "linux", win32: "windows" }[process.platform];
  // @ts-ignore
  const toolchain = { linux: "-musl", win32: "-gnu", darwin: "" }[process.platform];
  const arch = process.arch === "x64" ? "amd64" : process.arch;
  const ext = process.platform === "win32" ? ".exe" : "";

  return `https://github.com/matter-labs/era-compiler-solidity/releases/download/${PRE_RELEASE_VERSION}/zksolc-${platform}-${arch}${toolchain}-v${COMPILER_VERSION}${ext}`;
}

// These are L2/ETH networks defined by environment in `dev.env` of zksync-era default development environment
// const DEFAULT_L2_NETWORK = "http://127.0.0.1:3050";
const DEFAULT_ETH_NETWORK = "http://127.0.0.1:8545";

const zkSyncBaseNetworkEnv =
  process.env.CONTRACTS_BASE_NETWORK_ZKSYNC === "true"
    ? {
        ethNetwork: "localL1",
        zksync: true,
      }
    : {};

export default {
  defaultNetwork: "env",
  solidity: {
    version: "0.8.24",
    settings: {
      optimizer: {
        enabled: true,
        runs: 200,
      },
      outputSelection: {
        "*": {
          "*": ["storageLayout"],
        },
      },
      evmVersion: "cancun",
    },
  },
  zksolc: {
    compilerSource: "binary",
    settings: {
      compilerPath: getZksolcUrl(),
      isSystem: true,
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
      ...zkSyncBaseNetworkEnv,
    },
    hardhat: {
      allowUnlimitedContractSize: false,
      forking: {
        url: "https://eth-goerli.g.alchemy.com/v2/" + process.env.ALCHEMY_KEY,
        enabled: process.env.TEST_CONTRACTS_FORK === "1",
      },
    },
    localL1: {
      url: DEFAULT_ETH_NETWORK,
    },
  },
  etherscan: {
    apiKey: process.env.MISC_ETHERSCAN_API_KEY,
  },
  gasReporter: {
    enabled: true,
  },
};

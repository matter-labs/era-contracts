import "@matterlabs/hardhat-zksync-chai-matchers";
import "@matterlabs/hardhat-zksync-node";
import "@matterlabs/hardhat-zksync-solc";
import "@matterlabs/hardhat-zksync-verify";
import "@nomiclabs/hardhat-ethers";
import "hardhat-typechain";

// This version of system contracts requires a pre release of the compiler
const COMPILER_VERSION = "v1.5.6";
const PRE_RELEASE_VERSION = "1.5.6";
function getZksolcUrl(): string {
  // @ts-ignore
  const platform = { darwin: "macosx", linux: "linux", win32: "windows" }[process.platform];
  // @ts-ignore
  const toolchain = { linux: "-musl", win32: "-gnu", darwin: "" }[process.platform];
  const arch = process.arch === "x64" ? "amd64" : process.arch;
  const ext = process.platform === "win32" ? ".exe" : "";

  return `https://github.com/matter-labs/era-compiler-solidity/releases/download/${PRE_RELEASE_VERSION}/zksolc-${platform}-${arch}${toolchain}-${COMPILER_VERSION}${ext}`;
}

console.log(`Using zksolc from ${getZksolcUrl()}`);

export default {
  zksolc: {
    compilerSource: "binary",
    settings: {
      compilerPath: getZksolcUrl(),
      enableEraVMExtensions: true,
      suppressedErrors: ["sendtransfer"],
    },
  },
  zkSyncDeploy: {
    zkSyncNetwork: "http://localhost:3050",
    ethNetwork: "http://localhost:8545",
  },
  solidity: {
    version: "0.8.24",
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

import * as chalk from "chalk";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const warning = chalk.bold.yellow;
export const ADDRESS_ONE = "0x0000000000000000000000000000000000000001";
export const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";

interface SystemConfig {
  requiredL2GasPricePerPubdata: number;
  priorityTxMinimalGasPrice: number;
  priorityTxMaxGasPerBatch: number;
  priorityTxPubdataPerBatch: number;
  priorityTxBatchOverheadL1Gas: number;
  priorityTxMaxPubdata: number;
}

// eslint-disable-next-line @typescript-eslint/no-var-requires
const SYSTEM_CONFIG_JSON = require("../../SystemConfig.json");

export const SYSTEM_CONFIG: SystemConfig = {
  requiredL2GasPricePerPubdata: SYSTEM_CONFIG_JSON.REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
  priorityTxMinimalGasPrice: SYSTEM_CONFIG_JSON.PRIORITY_TX_MINIMAL_GAS_PRICE,
  priorityTxMaxGasPerBatch: SYSTEM_CONFIG_JSON.PRIORITY_TX_MAX_GAS_PER_BATCH,
  priorityTxPubdataPerBatch: SYSTEM_CONFIG_JSON.PRIORITY_TX_PUBDATA_PER_BATCH,
  priorityTxBatchOverheadL1Gas: SYSTEM_CONFIG_JSON.PRIORITY_TX_BATCH_OVERHEAD_L1_GAS,
  priorityTxMaxPubdata: SYSTEM_CONFIG_JSON.PRIORITY_TX_MAX_PUBDATA,
};

export function web3Url() {
  return process.env.ETH_CLIENT_WEB3_URL.split(",")[0] as string;
}

export function web3Provider() {
  const provider = new ethers.providers.JsonRpcProvider(web3Url());

  // Check that `CHAIN_ETH_NETWORK` variable is set. If not, it's most likely because
  // the variable was renamed. As this affects the time to deploy contracts in localhost
  // scenario, it surely deserves a warning.
  const network = process.env.CHAIN_ETH_NETWORK;
  if (!network) {
    console.log(warning("Network variable is not set. Check if contracts/scripts/utils.ts is correct"));
  }

  // Short polling interval for local network
  if (network === "localhost" || network === "hardhat") {
    provider.pollingInterval = 100;
  }

  return provider;
}

export function getAddressFromEnv(envName: string): string {
  const address = process.env[envName];
  if (!/^0x[a-fA-F0-9]{40}$/.test(address)) {
    throw new Error(`Incorrect address format hash in ${envName} env: ${address}`);
  }
  return address;
}

export function getHashFromEnv(envName: string): string {
  const hash = process.env[envName];
  if (!/^0x[a-fA-F0-9]{64}$/.test(hash)) {
    throw new Error(`Incorrect hash format hash in ${envName} env: ${hash}`);
  }
  return hash;
}

export function getNumberFromEnv(envName: string): string {
  const number = process.env[envName];
  if (!/^([1-9]\d*|0)$/.test(number)) {
    throw new Error(`Incorrect number format number in ${envName} env: ${number}`);
  }
  return number;
}

export function readBatchBootloaderBytecode() {
  const bootloaderPath = path.join(process.env.ZKSYNC_HOME as string, "contracts/system-contracts/bootloader");
  return fs.readFileSync(`${bootloaderPath}/build/artifacts/proved_batch.yul.zbin`);
}

export function readSystemContractsBytecode(fileName: string) {
  const systemContractsPath = path.join(process.env.ZKSYNC_HOME as string, "contracts/system-contracts");
  const artifact = fs.readFileSync(
    `${systemContractsPath}/artifacts-zk/contracts-preprocessed/${fileName}.sol/${fileName}.json`
  );
  return JSON.parse(artifact.toString()).bytecode;
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export function print(name: string, data: any) {
  console.log(`${name}:\n`, JSON.stringify(data, null, 4), "\n");
}

export function getLowerCaseAddress(address: string) {
  return ethers.utils.getAddress(address).toLowerCase();
}

export type L1Token = {
  name: string;
  symbol: string;
  decimals: number;
  address: string;
};

export function getTokens(network: string): L1Token[] {
  const configPath =
    network == "hardhat"
      ? `./test/test_config/constant/${network}.json`
      : `${process.env.ZKSYNC_HOME}/etc/tokens/${network}.json`;
  return JSON.parse(
    fs.readFileSync(configPath, {
      encoding: "utf-8",
    })
  );
}

export interface DeployedAddresses {
  Bridgehub: {
    BridgehubProxy: string;
    BridgehubImplementation: string;
  };
  StateTransition: {
    StateTransitionProxy: string;
    StateTransitionImplementation: string;
    Verifier: string;
    AdminFacet: string;
    MailboxFacet: string;
    ExecutorFacet: string;
    GettersFacet: string;
    DiamondInit: string;
    GenesisUpgrade: string;
    DiamondUpgradeInit: string;
    DefaultUpgrade: string;
    DiamondProxy: string;
  };
  Bridges: {
    ERC20BridgeImplementation: string;
    ERC20BridgeMessageParsing: string;
    ERC20BridgeProxy: string;
    WethBridgeImplementation: string;
    WethBridgeProxy: string;
    BaseTokenBridge: string;
  };
  BaseToken: string;
  TransparentProxyAdmin: string;
  Governance: string;
  ValidatorTimeLock: string;
  Create2Factory: string;
}

export function deployedAddressesFromEnv(): DeployedAddresses {
  return {
    Bridgehub: {
      BridgehubProxy: getAddressFromEnv("CONTRACTS_BRIDGEHUB_PROXY_ADDR"),
      BridgehubImplementation: getAddressFromEnv("CONTRACTS_BRIDGEHUB_IMPL_ADDR"),
    },
    StateTransition: {
      StateTransitionProxy: getAddressFromEnv("CONTRACTS_STATE_TRANSITION_PROXY_ADDR"),
      StateTransitionImplementation: getAddressFromEnv("CONTRACTS_STATE_TRANSITION_IMPL_ADDR"),
      Verifier: getAddressFromEnv("CONTRACTS_VERIFIER_ADDR"),
      AdminFacet: getAddressFromEnv("CONTRACTS_ADMIN_FACET_ADDR"),
      MailboxFacet: getAddressFromEnv("CONTRACTS_MAILBOX_FACET_ADDR"),
      ExecutorFacet: getAddressFromEnv("CONTRACTS_EXECUTOR_FACET_ADDR"),
      GettersFacet: getAddressFromEnv("CONTRACTS_GETTERS_FACET_ADDR"),
      DiamondInit: getAddressFromEnv("CONTRACTS_DIAMOND_INIT_ADDR"),
      GenesisUpgrade: getAddressFromEnv("CONTRACTS_GENESIS_UPGRADE_ADDR"),
      DiamondUpgradeInit: getAddressFromEnv("CONTRACTS_DIAMOND_UPGRADE_INIT_ADDR"),
      DefaultUpgrade: getAddressFromEnv("CONTRACTS_DEFAULT_UPGRADE_ADDR"),
      DiamondProxy: getAddressFromEnv("CONTRACTS_DIAMOND_PROXY_ADDR"),
    },
    Bridges: {
      ERC20BridgeImplementation: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR"),
      ERC20BridgeMessageParsing: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_MESSAGE_PARSING_ADDR"),
      ERC20BridgeProxy: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR"),
      WethBridgeImplementation: getAddressFromEnv("CONTRACTS_L1_WETH_BRIDGE_IMPL_ADDR"),
      WethBridgeProxy: getAddressFromEnv("CONTRACTS_L1_WETH_BRIDGE_PROXY_ADDR"),
      BaseTokenBridge: getAddressFromEnv("CONTRACTS_BASE_TOKEN_BRIDGE_ADDR"),
    },
    BaseToken: getAddressFromEnv("CONTRACTS_BASE_TOKEN_ADDR"),
    TransparentProxyAdmin: getAddressFromEnv("CONTRACTS_TRANSPARENT_PROXY_ADMIN_ADDR"),
    Create2Factory: getAddressFromEnv("CONTRACTS_CREATE2_FACTORY_ADDR"),
    ValidatorTimeLock: getAddressFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_ADDR"),
    Governance: getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR"),
  };
}

export enum PubdataPricingMode {
  Rollup = 0,
  Porter = 1,
}

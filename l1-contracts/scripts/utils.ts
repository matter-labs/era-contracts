import * as chalk from "chalk";
import type { BytesLike } from "ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const warning = chalk.bold.yellow;
const CREATE2_PREFIX = ethers.utils.solidityKeccak256(["string"], ["zksyncCreate2"]);
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
  if (network === "localhost") {
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

const ADDRESS_MODULO = ethers.BigNumber.from(2).pow(160);

export function applyL1ToL2Alias(address: string): string {
  return ethers.utils.hexlify(ethers.BigNumber.from(address).add(L1_TO_L2_ALIAS_OFFSET).mod(ADDRESS_MODULO));
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

export function hashL2Bytecode(bytecode: ethers.BytesLike): Uint8Array {
  // For getting the consistent length we first convert the bytecode to UInt8Array
  const bytecodeAsArray = ethers.utils.arrayify(bytecode);

  if (bytecodeAsArray.length % 32 != 0) {
    throw new Error("The bytecode length in bytes must be divisible by 32");
  }

  const hashStr = ethers.utils.sha256(bytecodeAsArray);
  const hash = ethers.utils.arrayify(hashStr);

  // Note that the length of the bytecode
  // should be provided in 32-byte words.
  const bytecodeLengthInWords = bytecodeAsArray.length / 32;
  if (bytecodeLengthInWords % 2 == 0) {
    throw new Error("Bytecode length in 32-byte words must be odd");
  }
  const bytecodeLength = ethers.utils.arrayify(bytecodeAsArray.length / 32);
  if (bytecodeLength.length > 2) {
    throw new Error("Bytecode length must be less than 2^16 bytes");
  }
  // The bytecode should always take the first 2 bytes of the bytecode hash,
  // so we pad it from the left in case the length is smaller than 2 bytes.
  const bytecodeLengthPadded = ethers.utils.zeroPad(bytecodeLength, 2);

  const codeHashVersion = new Uint8Array([1, 0]);
  hash.set(codeHashVersion, 0);
  hash.set(bytecodeLengthPadded, 2);

  return hash;
}

export function computeL2Create2Address(
  deployWallet: string,
  bytecode: BytesLike,
  constructorInput: BytesLike,
  create2Salt: BytesLike
) {
  const senderBytes = ethers.utils.hexZeroPad(deployWallet, 32);
  const bytecodeHash = hashL2Bytecode(bytecode);

  const constructorInputHash = ethers.utils.keccak256(constructorInput);

  const data = ethers.utils.keccak256(
    ethers.utils.concat([CREATE2_PREFIX, senderBytes, create2Salt, bytecodeHash, constructorInputHash])
  );

  return ethers.utils.hexDataSlice(data, 12);
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
  const configPath = `${process.env.ZKSYNC_HOME}/etc/tokens/${network}.json`;
  return JSON.parse(
    fs.readFileSync(configPath, {
      encoding: "utf-8",
    })
  );
}

export interface DeployedAddresses {
  ZkSync: {
    MailboxFacet: string;
    AdminFacet: string;
    ExecutorFacet: string;
    GettersFacet: string;
    Verifier: string;
    DiamondInit: string;
    DiamondUpgradeInit: string;
    DefaultUpgrade: string;
    DiamondProxy: string;
  };
  Bridges: {
    ERC20BridgeImplementation: string;
    ERC20BridgeProxy: string;
    WethBridgeImplementation: string;
    WethBridgeProxy: string;
  };
  Governance: string;
  ValidatorTimeLock: string;
  Create2Factory: string;
}

export function deployedAddressesFromEnv(): DeployedAddresses {
  return {
    ZkSync: {
      MailboxFacet: getAddressFromEnv("CONTRACTS_MAILBOX_FACET_ADDR"),
      AdminFacet: getAddressFromEnv("CONTRACTS_ADMIN_FACET_ADDR"),
      ExecutorFacet: getAddressFromEnv("CONTRACTS_EXECUTOR_FACET_ADDR"),
      GettersFacet: getAddressFromEnv("CONTRACTS_GETTERS_FACET_ADDR"),
      DiamondInit: getAddressFromEnv("CONTRACTS_DIAMOND_INIT_ADDR"),
      DiamondUpgradeInit: getAddressFromEnv("CONTRACTS_DIAMOND_UPGRADE_INIT_ADDR"),
      DefaultUpgrade: getAddressFromEnv("CONTRACTS_DEFAULT_UPGRADE_ADDR"),
      DiamondProxy: getAddressFromEnv("CONTRACTS_DIAMOND_PROXY_ADDR"),
      Verifier: getAddressFromEnv("CONTRACTS_VERIFIER_ADDR"),
    },
    Bridges: {
      ERC20BridgeImplementation: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_IMPL_ADDR"),
      ERC20BridgeProxy: getAddressFromEnv("CONTRACTS_L1_ERC20_BRIDGE_PROXY_ADDR"),
      WethBridgeImplementation: getAddressFromEnv("CONTRACTS_L1_WETH_BRIDGE_IMPL_ADDR"),
      WethBridgeProxy: getAddressFromEnv("CONTRACTS_L1_WETH_BRIDGE_PROXY_ADDR"),
    },
    Create2Factory: getAddressFromEnv("CONTRACTS_CREATE2_FACTORY_ADDR"),
    ValidatorTimeLock: getAddressFromEnv("CONTRACTS_VALIDATOR_TIMELOCK_ADDR"),
    Governance: getAddressFromEnv("CONTRACTS_GOVERNANCE_ADDR"),
  };
}

export enum PubdataPricingMode {
  Rollup = 0,
  Porter = 1,
}

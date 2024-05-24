// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
import * as chalk from "chalk";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";

const warning = chalk.bold.yellow;
export const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";
export const GAS_MULTIPLIER = 1;

// Bit shift by 32 does not work in JS, so we have to multiply by 2^32
export const SEMVER_MINOR_VERSION_MULTIPLIER = 4294967296;

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

export function unpackStringSemVer(semver: string): [number, number, number] {
  const [major, minor, patch] = semver.split(".");
  return [parseInt(major), parseInt(minor), parseInt(patch)];
}

function unpackNumberSemVer(semver: number): [number, number, number] {
  const major = 0;
  const minor = Math.floor(semver / SEMVER_MINOR_VERSION_MULTIPLIER);
  const patch = semver % SEMVER_MINOR_VERSION_MULTIPLIER;
  return [major, minor, patch];
}

// The major version is always 0 for now
export function packSemver(major: number, minor: number, patch: number) {
  if (major !== 0) {
    throw new Error("Major version must be 0");
  }

  return minor * SEMVER_MINOR_VERSION_MULTIPLIER + patch;
}

export function addToProtocolVersion(packedProtocolVersion: number, minor: number, patch: number) {
  const [major, minorVersion, patchVersion] = unpackNumberSemVer(packedProtocolVersion);
  return packSemver(major, minorVersion + minor, patchVersion + patch);
}

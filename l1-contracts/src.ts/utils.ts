// hardhat import should be the first import in the file
// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";

import type { BytesLike, BigNumberish } from "ethers";
import { ethers } from "ethers";
import * as fs from "fs";
import * as path from "path";
import { DiamondInitFactory } from "../typechain";
import type { DiamondCut, FacetCut } from "./diamondCut";
import { diamondCut } from "./diamondCut";
import { SYSTEM_CONFIG } from "../scripts/utils";

export const testConfigPath = process.env.ZKSYNC_ENV
  ? path.join(process.env.ZKSYNC_HOME as string, "etc/test_config/constant")
  : "./test/test_config/constant";
export const ethTestConfig = JSON.parse(fs.readFileSync(`${testConfigPath}/eth.json`, { encoding: "utf-8" }));

// eslint-disable-next-line @typescript-eslint/no-var-requires
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

export const SYSTEM_UPGRADE_L2_TX_TYPE = 254;
export const ADDRESS_ONE = "0x0000000000000000000000000000000000000001";
export const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";
export const EMPTY_STRING_KECCAK = "0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470";
const CREATE2_PREFIX = ethers.utils.solidityKeccak256(["string"], ["zksyncCreate2"]);

const ADDRESS_MODULO = ethers.BigNumber.from(2).pow(160);
export const DIAMOND_CUT_DATA_ABI_STRING =
  "tuple(tuple(address facet, uint8 action, bool isFreezable, bytes4[] selectors)[] facetCuts, address initAddress, bytes initCalldata)";

export function applyL1ToL2Alias(address: string): string {
  return ethers.utils.hexlify(ethers.BigNumber.from(address).add(L1_TO_L2_ALIAS_OFFSET).mod(ADDRESS_MODULO));
}

export function readBytecode(path: string, fileName: string) {
  return JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: "utf-8" })).bytecode;
}

export function readInterface(path: string, fileName: string) {
  const abi = JSON.parse(fs.readFileSync(`${path}/${fileName}.sol/${fileName}.json`, { encoding: "utf-8" })).abi;
  return new ethers.utils.Interface(abi);
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

export enum PubdataPricingMode {
  Rollup,
  Validium,
}

export interface FeeParams {
  pubdataPricingMode: PubdataPricingMode;
  batchOverheadL1Gas: number;
  maxPubdataPerBatch: number;
  maxL2GasPerBatch: number;
  priorityTxMaxPubdata: number;
  minimalL2GasPrice: BigNumberish;
}

export interface ProposedUpgrade {
  // The tx for the upgrade call to the l2 system upgrade contract
  l2ProtocolUpgradeTx: L2CanonicalTransaction;
  factoryDeps: BytesLike[];
  bootloaderHash: BytesLike;
  defaultAccountHash: BytesLike;
  verifier: string;
  verifierParams: VerifierParams;
  l1ContractsUpgradeCalldata: BytesLike;
  postUpgradeCalldata: BytesLike;
  upgradeTimestamp: ethers.BigNumber;
  newProtocolVersion: BigNumberish;
}

export interface VerifierParams {
  recursionNodeLevelVkHash: BytesLike;
  recursionLeafLevelVkHash: BytesLike;
  recursionCircuitsSetVksHash: BytesLike;
}

export interface L2CanonicalTransaction {
  txType: BigNumberish;
  from: BigNumberish;
  to: BigNumberish;
  gasLimit: BigNumberish;
  gasPerPubdataByteLimit: BigNumberish;
  maxFeePerGas: BigNumberish;
  maxPriorityFeePerGas: BigNumberish;
  paymaster: BigNumberish;
  nonce: BigNumberish;
  value: BigNumberish;
  // In the future, we might want to add some
  // new fields to the struct. The `txData` struct
  // is to be passed to account and any changes to its structure
  // would mean a breaking change to these accounts. In order to prevent this,
  // we should keep some fields as "reserved".
  // It is also recommended that their length is fixed, since
  // it would allow easier proof integration (in case we will need
  // some special circuit for preprocessing transactions).
  reserved: [BigNumberish, BigNumberish, BigNumberish, BigNumberish];
  data: BytesLike;
  signature: BytesLike;
  factoryDeps: BigNumberish[];
  paymasterInput: BytesLike;
  // Reserved dynamic type for the future use-case. Using it should be avoided,
  // But it is still here, just in case we want to enable some additional functionality.
  reservedDynamic: BytesLike;
}

// Checks that the initial cut hash params are valid.
// Sometimes it makes sense to allow dummy values for testing purposes, but in production
// these values should be set correctly.
function checkValidInitialCutHashParams(
  facetCuts: FacetCut[],
  verifierParams: VerifierParams,
  l2BootloaderBytecodeHash: string,
  l2DefaultAccountBytecodeHash: string,
  verifier: string,
  blobVersionedHashRetriever: string,
  priorityTxMaxGasLimit: number
) {
  // We do not fetch the following numbers from the environment because they are very rarely changed
  // and we want to avoid the risk of accidentally changing them.
  const EXPECTED_FACET_CUTS = 4;
  const EXPECTED_PRIORITY_TX_MAX_GAS_LIMIT = 72_000_000;

  if (facetCuts.length != EXPECTED_FACET_CUTS) {
    throw new Error(`Expected ${EXPECTED_FACET_CUTS} facet cuts, got ${facetCuts.length}`);
  }

  if (verifierParams.recursionNodeLevelVkHash === ethers.constants.HashZero) {
    throw new Error("Recursion node level vk hash is zero");
  }
  if (verifierParams.recursionLeafLevelVkHash === ethers.constants.HashZero) {
    throw new Error("Recursion leaf level vk hash is zero");
  }
  if (verifierParams.recursionCircuitsSetVksHash !== ethers.constants.HashZero) {
    throw new Error("Recursion circuits set vks hash must be zero");
  }
  if (l2BootloaderBytecodeHash === ethers.constants.HashZero) {
    throw new Error("L2 bootloader bytecode hash is zero");
  }
  if (l2DefaultAccountBytecodeHash === ethers.constants.HashZero) {
    throw new Error("L2 default account bytecode hash is zero");
  }
  if (verifier === ethers.constants.AddressZero) {
    throw new Error("Verifier address is zero");
  }
  if (blobVersionedHashRetriever === ethers.constants.AddressZero) {
    throw new Error("Blob versioned hash retriever address is zero");
  }
  if (priorityTxMaxGasLimit !== EXPECTED_PRIORITY_TX_MAX_GAS_LIMIT) {
    throw new Error(
      `Expected priority tx max gas limit to be ${EXPECTED_PRIORITY_TX_MAX_GAS_LIMIT}, got ${priorityTxMaxGasLimit}`
    );
  }
}

// We should either reuse code or add a test for this function.
export function compileInitialCutHash(
  facetCuts: FacetCut[],
  verifierParams: VerifierParams,
  l2BootloaderBytecodeHash: string,
  l2DefaultAccountBytecodeHash: string,
  verifier: string,
  blobVersionedHashRetriever: string,
  priorityTxMaxGasLimit: number,
  diamondInit: string,
  strictMode: boolean = true
): DiamondCut {
  if (strictMode) {
    checkValidInitialCutHashParams(
      facetCuts,
      verifierParams,
      l2BootloaderBytecodeHash,
      l2DefaultAccountBytecodeHash,
      verifier,
      blobVersionedHashRetriever,
      priorityTxMaxGasLimit
    );
  }

  const factory = new DiamondInitFactory();

  const feeParams = {
    pubdataPricingMode: PubdataPricingMode.Rollup,
    batchOverheadL1Gas: SYSTEM_CONFIG.priorityTxBatchOverheadL1Gas,
    maxPubdataPerBatch: SYSTEM_CONFIG.priorityTxPubdataPerBatch,
    priorityTxMaxPubdata: SYSTEM_CONFIG.priorityTxMaxPubdata,
    maxL2GasPerBatch: SYSTEM_CONFIG.priorityTxMaxGasPerBatch,
    minimalL2GasPrice: SYSTEM_CONFIG.priorityTxMinimalGasPrice,
  };

  const diamondInitCalldata = factory.interface.encodeFunctionData("initialize", [
    // these first values are set in the contract
    {
      chainId: "0x0000000000000000000000000000000000000000000000000000000000000001",
      bridgehub: "0x0000000000000000000000000000000000001234",
      stateTransitionManager: "0x0000000000000000000000000000000000002234",
      protocolVersion: "0x0000000000000000000000000000000000002234",
      admin: "0x0000000000000000000000000000000000003234",
      validatorTimelock: "0x0000000000000000000000000000000000004234",
      baseToken: "0x0000000000000000000000000000000000004234",
      baseTokenBridge: "0x0000000000000000000000000000000000004234",
      storedBatchZero: "0x0000000000000000000000000000000000000000000000000000000000005432",
      verifier,
      verifierParams,
      l2BootloaderBytecodeHash,
      l2DefaultAccountBytecodeHash,
      priorityTxMaxGasLimit,
      feeParams,
      blobVersionedHashRetriever,
    },
  ]);

  return diamondCut(facetCuts, diamondInit, "0x" + diamondInitCalldata.slice(2 + (4 + 9 * 32) * 2));
}

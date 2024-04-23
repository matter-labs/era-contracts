// hardhat import should be the first import in the file
import * as hre from "hardhat";

import { ethers } from "ethers";
import { existsSync, mkdirSync, writeFileSync, readFileSync } from "fs";
import { render, renderFile } from "template-file";
import { utils } from "zksync-ethers";
import { getRevertSelector, getTransactionUtils } from "./constants";

/* eslint-disable @typescript-eslint/no-var-requires */
const preprocess = require("preprocess");
const SYSTEM_PARAMS = require("../../SystemConfig.json");
/* eslint-enable@typescript-eslint/no-var-requires */

const OUTPUT_DIR = "bootloader/build";

const PREPROCCESING_MODES = ["proved_batch", "playground_batch"];

function getSelector(contractName: string, method: string): string {
  const artifact = hre.artifacts.readArtifactSync(contractName);
  const contractInterface = new ethers.utils.Interface(artifact.abi);

  return contractInterface.getSighash(method);
}

// Methods from ethers do zero pad from left, but we need to pad from the right
function padZeroRight(hexData: string, length: number): string {
  while (hexData.length < length) {
    hexData += "0";
  }

  return hexData;
}

const PADDED_SELECTOR_LENGTH = 32 * 2 + 2;
function getPaddedSelector(contractName: string, method: string): string {
  const result = getSelector(contractName, method);

  return padZeroRight(result, PADDED_SELECTOR_LENGTH);
}

function getSystemContextCodeHash() {
  const bytecode = hre.artifacts.readArtifactSync("SystemContext").bytecode;
  return ethers.utils.hexlify(utils.hashBytecode(bytecode));
}

// Maybe in the future some of these params will be passed
// in a JSON file. For now, a simple object is ok here.
const params = {
  MARK_BATCH_AS_REPUBLISHED_SELECTOR: getSelector("KnownCodesStorage", "markFactoryDeps"),
  VALIDATE_TX_SELECTOR: getSelector("IAccount", "validateTransaction"),
  EXECUTE_TX_SELECTOR: getSelector("DefaultAccount", "executeTransaction"),
  RIGHT_PADDED_GET_ACCOUNT_VERSION_SELECTOR: getPaddedSelector("ContractDeployer", "extendedAccountVersion"),
  RIGHT_PADDED_GET_RAW_CODE_HASH_SELECTOR: getPaddedSelector("AccountCodeStorage", "getRawCodeHash"),
  PAY_FOR_TX_SELECTOR: getSelector("DefaultAccount", "payForTransaction"),
  PRE_PAYMASTER_SELECTOR: getSelector("DefaultAccount", "prepareForPaymaster"),
  VALIDATE_AND_PAY_PAYMASTER: getSelector("IPaymaster", "validateAndPayForPaymasterTransaction"),
  // It doesn't used directly now but is important to keep the way to regenerate it when needed
  TX_UTILITIES: getTransactionUtils(),
  RIGHT_PADDED_POST_TRANSACTION_SELECTOR: getPaddedSelector("IPaymaster", "postTransaction"),
  RIGHT_PADDED_SET_TX_ORIGIN: getPaddedSelector("SystemContext", "setTxOrigin"),
  RIGHT_PADDED_SET_GAS_PRICE: getPaddedSelector("SystemContext", "setGasPrice"),
  RIGHT_PADDED_SET_PUBDATA_INFO: getPaddedSelector("SystemContext", "setPubdataInfo"),
  RIGHT_PADDED_INCREMENT_TX_NUMBER_IN_BLOCK_SELECTOR: getPaddedSelector("SystemContext", "incrementTxNumberInBatch"),
  RIGHT_PADDED_RESET_TX_NUMBER_IN_BLOCK_SELECTOR: getPaddedSelector("SystemContext", "resetTxNumberInBatch"),
  RIGHT_PADDED_SEND_L2_TO_L1_LOG_SELECTOR: getPaddedSelector("L1Messenger", "sendL2ToL1Log"),
  PUBLISH_PUBDATA_SELECTOR: getSelector("L1Messenger", "publishPubdataAndClearState"),
  RIGHT_PADDED_SET_NEW_BATCH_SELECTOR: getPaddedSelector("SystemContext", "setNewBatch"),
  RIGHT_PADDED_OVERRIDE_BATCH_SELECTOR: getPaddedSelector("SystemContext", "unsafeOverrideBatch"),
  // Error
  REVERT_ERROR_SELECTOR: padZeroRight(getRevertSelector(), PADDED_SELECTOR_LENGTH),
  RIGHT_PADDED_VALIDATE_NONCE_USAGE_SELECTOR: getPaddedSelector("INonceHolder", "validateNonceUsage"),
  RIGHT_PADDED_MINT_ETHER_SELECTOR: getPaddedSelector("L2BaseToken", "mint"),
  GET_TX_HASHES_SELECTOR: getSelector("BootloaderUtilities", "getTransactionHashes"),
  CREATE_SELECTOR: getSelector("ContractDeployer", "create"),
  CREATE2_SELECTOR: getSelector("ContractDeployer", "create2"),
  CREATE_ACCOUNT_SELECTOR: getSelector("ContractDeployer", "createAccount"),
  CREATE2_ACCOUNT_SELECTOR: getSelector("ContractDeployer", "create2Account"),
  PADDED_TRANSFER_FROM_TO_SELECTOR: getPaddedSelector("L2BaseToken", "transferFromTo"),
  SUCCESSFUL_ACCOUNT_VALIDATION_MAGIC_VALUE: getPaddedSelector("IAccount", "validateTransaction"),
  SUCCESSFUL_PAYMASTER_VALIDATION_MAGIC_VALUE: getPaddedSelector("IPaymaster", "validateAndPayForPaymasterTransaction"),
  PUBLISH_COMPRESSED_BYTECODE_SELECTOR: getSelector("Compressor", "publishCompressedBytecode"),
  GET_MARKER_PADDED_SELECTOR: getPaddedSelector("KnownCodesStorage", "getMarker"),
  RIGHT_PADDED_SET_L2_BLOCK_SELECTOR: getPaddedSelector("SystemContext", "setL2Block"),
  RIGHT_PADDED_APPEND_TRANSACTION_TO_L2_BLOCK_SELECTOR: getPaddedSelector(
    "SystemContext",
    "appendTransactionToCurrentL2Block"
  ),
  RIGHT_PADDED_PUBLISH_TIMESTAMP_DATA_TO_L1_SELECTOR: getPaddedSelector("SystemContext", "publishTimestampDataToL1"),
  COMPRESSED_BYTECODES_SLOTS: 196608,
  ENSURE_RETURNED_MAGIC: 1,
  FORBID_ZERO_GAS_PER_PUBDATA: 1,
  SYSTEM_CONTEXT_EXPECTED_CODE_HASH: getSystemContextCodeHash(),
  PADDED_FORCE_DEPLOY_ON_ADDRESSES_SELECTOR: getPaddedSelector("ContractDeployer", "forceDeployOnAddresses"),
  // One of "worst case" scenarios for the number of state diffs in a batch is when 780kb of pubdata is spent
  // on repeated writes, that are all zeroed out. In this case, the number of diffs is 780kb / 5 = 156k. This means that they will have
  // accoomdate 42432000 bytes of calldata for the uncompressed state diffs. Adding 780kb on top leaves us with
  // roughly 43212000 bytes needed for calldata.
  // 1350375 slots are needed to accommodate this amount of data. We round up to 1360000 slots just in case.
  //
  // In theory though much more calldata could be used (if for instance 1 byte is used for enum index). It is the responsibility of the
  // operator to ensure that it can form the correct calldata for the L1Messenger.
  OPERATOR_PROVIDED_L1_MESSENGER_PUBDATA_SLOTS: 1360000,
  ...SYSTEM_PARAMS,
};

function extractTestFunctionNames(sourceCode: string): string[] {
  // Remove single-line comments
  sourceCode = sourceCode.replace(/\/\/[^\n]*/g, "");

  // Remove multi-line comments
  sourceCode = sourceCode.replace(/\/\*[\s\S]*?\*\//g, "");

  const regexPatterns = [/function\s+(TEST\w+)/g];

  const results: string[] = [];
  for (const pattern of regexPatterns) {
    let match;
    while ((match = pattern.exec(sourceCode)) !== null) {
      results.push(match[1]);
    }
  }

  return [...new Set(results)]; // Remove duplicates
}

function createTestFramework(tests: string[]): string {
  let testFramework = `
    let test_id:= mload(0)

    switch test_id
    case 0 {
        testing_totalTests(${tests.length})
    }
    `;

  tests.forEach((value, index) => {
    testFramework += `
        case ${index + 1} {
            testing_start("${value}")
            ${value}()
        }
        `;
  });

  testFramework += `
        default {
        }
    return (0, 0)
    `;

  return testFramework;
}

function validateSource(source: string) {
  const matches = source.matchAll(/<!-- @if BOOTLOADER_TYPE=='([^']*)' -->/g);
  for (const match of matches) {
    if (!PREPROCCESING_MODES.includes(match[1])) {
      throw Error(`Invalid preprocessing mode '${match[1]}' at position ${match.index}`);
    }
  }
}

async function main() {
  const bootloaderSource = readFileSync("bootloader/bootloader.yul").toString();
  validateSource(bootloaderSource);

  const bootloader = await render(bootloaderSource, params);
  // The overhead is unknown for gas tests and so it should be zero to calculate it
  const gasTestBootloaderTemplate = await render(bootloaderSource, {
    ...params,
    L2_TX_INTRINSIC_GAS: 0,
    L2_TX_INTRINSIC_PUBDATA: 0,
    L1_TX_INTRINSIC_L2_GAS: 0,
    L1_TX_INTRINSIC_PUBDATA: 0,
    FORBID_ZERO_GAS_PER_PUBDATA: 0,
  });

  const feeEstimationBootloaderTemplate = await render(bootloaderSource, {
    ...params,
    ENSURE_RETURNED_MAGIC: 0,
  });

  console.log("Preprocessing production bootloader");
  const provedBatchBootloader = preprocess.preprocess(bootloader, { BOOTLOADER_TYPE: "proved_batch" });
  console.log("Preprocessing playground block bootloader");
  const playgroundBatchBootloader = preprocess.preprocess(bootloader, { BOOTLOADER_TYPE: "playground_batch" });
  console.log("Preprocessing gas test bootloader");
  const gasTestBootloader = preprocess.preprocess(gasTestBootloaderTemplate, { BOOTLOADER_TYPE: "proved_batch" });
  console.log("Preprocessing fee estimation bootloader");
  const feeEstimationBootloader = preprocess.preprocess(feeEstimationBootloaderTemplate, {
    BOOTLOADER_TYPE: "playground_batch",
  });

  console.log("Preprocessing bootloader tests");
  const bootloaderTests = await renderFile("bootloader/tests/bootloader/bootloader_test.yul", {});

  const testMethods = extractTestFunctionNames(bootloaderTests);

  console.log("Found tests: " + testMethods);

  const testFramework = createTestFramework(testMethods);

  const bootloaderTestUtils = await renderFile("bootloader/tests/utils/test_utils.yul", {});

  const bootloaderWithTests = await render(bootloaderSource, {
    ...params,
    CODE_START_PLACEHOLDER: "\n" + bootloaderTestUtils + "\n" + bootloaderTests + "\n" + testFramework,
  });
  const provedBootloaderWithTests = preprocess.preprocess(bootloaderWithTests, { BOOTLOADER_TYPE: "proved_batch" });

  if (!existsSync(OUTPUT_DIR)) {
    mkdirSync(OUTPUT_DIR);
  }

  writeFileSync(`${OUTPUT_DIR}/bootloader_test.yul`, provedBootloaderWithTests);
  writeFileSync(`${OUTPUT_DIR}/proved_batch.yul`, provedBatchBootloader);
  writeFileSync(`${OUTPUT_DIR}/playground_batch.yul`, playgroundBatchBootloader);
  writeFileSync(`${OUTPUT_DIR}/gas_test.yul`, gasTestBootloader);
  writeFileSync(`${OUTPUT_DIR}/fee_estimate.yul`, feeEstimationBootloader);

  console.log("Bootloader preprocessing done!");
}

main();

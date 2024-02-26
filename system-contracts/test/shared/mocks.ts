import { ethers } from "hardhat";
import type { MockContract } from "../../typechain";
import { MockContractFactory } from "../../typechain";
import {
  TEST_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TEST_BASE_TOKEN_SYSTEM_CONTRACT_ADDRESS,
  TEST_IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT_ADDRESS,
  TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TEST_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS,
  TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS,
  TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS,
  TEST_COMPRESSOR_CONTRACT_ADDRESS,
  TEST_PUBDATA_CHUNK_PUBLISHER_ADDRESS,
} from "./constants";
import { deployContractOnAddress, getWallets, loadArtifact } from "./utils";

type CallResult = {
  failure: boolean;
  returnData: string;
};

// Currently listed only contracts, that actually need to be mocked in the tests.
// But other contracts can be added if needed.
const TEST_SYSTEM_CONTRACTS_MOCKS = {
  Compressor: TEST_COMPRESSOR_CONTRACT_ADDRESS,
  SystemContext: TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS,
  NonceHolder: TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS,
  L1Messenger: TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  KnownCodesStorage: TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
  AccountCodeStorage: TEST_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
  L2BaseToken: TEST_BASE_TOKEN_SYSTEM_CONTRACT_ADDRESS,
  ImmutableSimulator: TEST_IMMUTABLE_SIMULATOR_SYSTEM_CONTRACT_ADDRESS,
  MsgValueSimulator: TEST_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS,
  Bootloader: TEST_BOOTLOADER_FORMAL_ADDRESS,
  PubdataChunkPublisher: TEST_PUBDATA_CHUNK_PUBLISHER_ADDRESS,
};

// Deploys mocks, and cleans previous call results during deployments.
// Usually should be called once per one system contract tests set.
export async function prepareEnvironment() {
  for (const address of Object.values(TEST_SYSTEM_CONTRACTS_MOCKS)) {
    await deployContractOnAddress(address, "MockContract");
  }
}

// set the call result for the mocked system contract
export async function setResult(
  contractName: string,
  functionName: string,
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  args: any[] | string | undefined,
  result: CallResult
) {
  const mock = getMock(contractName);
  const calldata = encodeCalldata(contractName, functionName, args);
  await mock.setResult({ input: calldata, failure: result.failure, returnData: result.returnData });
}

// eslint-disable-next-line @typescript-eslint/no-explicit-any
export async function encodeCalldata(contractName: string, functionName: string, args: any[] | string | undefined) {
  let calldata: string;
  if (functionName === "") {
    if (typeof args !== "string") {
      throw "Invalid args for the fallback";
    }
    calldata = args;
  } else {
    const iface = new ethers.utils.Interface((await loadArtifact(contractName)).abi);
    calldata = iface.encodeFunctionData(functionName, args);
  }
  return calldata;
}

export function getMock(contractName: string): MockContract {
  const address = TEST_SYSTEM_CONTRACTS_MOCKS[contractName];
  if (address === undefined) {
    throw `Test system contract ${contractName} not found`;
  }
  return MockContractFactory.connect(address, getWallets()[0]);
}

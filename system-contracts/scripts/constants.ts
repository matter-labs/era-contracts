import type { BigNumberish, BytesLike } from "ethers";
import { constants, ethers } from "ethers";

export const BOOTLOADER_FORMAL_ADDRESS = "0x0000000000000000000000000000000000008001";
export const ETH_ADDRESS = constants.AddressZero;

export enum Language {
  Solidity = "solidity",
  Yul = "yul",
  Zasm = "zasm",
}

export interface SystemContractDescription {
  address: string;
  codeName: string;
}

export interface YulContractDescription extends SystemContractDescription {
  lang: Language.Yul;
  path: string;
}

// Currently used only for the tests
export interface ZasmContractDescription extends SystemContractDescription {
  lang: Language.Zasm;
  path: string;
}

export interface SolidityContractDescription extends SystemContractDescription {
  lang: Language.Solidity;
}

interface ISystemContracts {
  [key: string]: YulContractDescription | SolidityContractDescription;
}

export const SYSTEM_CONTRACTS: ISystemContracts = {
  zeroAddress: {
    // zero address has EmptyContract code
    address: "0x0000000000000000000000000000000000000000",
    codeName: "EmptyContract",
    lang: Language.Solidity,
  },
  ecrecover: {
    address: "0x0000000000000000000000000000000000000001",
    codeName: "Ecrecover",
    lang: Language.Yul,
    path: "precompiles",
  },
  sha256: {
    address: "0x0000000000000000000000000000000000000002",
    codeName: "SHA256",
    lang: Language.Yul,
    path: "precompiles",
  },
  ecAdd: {
    address: "0x0000000000000000000000000000000000000006",
    codeName: "EcAdd",
    lang: Language.Yul,
    path: "precompiles",
  },
  ecMul: {
    address: "0x0000000000000000000000000000000000000007",
    codeName: "EcMul",
    lang: Language.Yul,
    path: "precompiles",
  },
  ecPairing: {
    address: "0x0000000000000000000000000000000000000008",
    codeName: "EcPairing",
    lang: Language.Yul,
    path: "precompiles",
  },
  bootloader: {
    // Bootloader has EmptyContract code
    address: "0x0000000000000000000000000000000000008001",
    codeName: "EmptyContract",
    lang: Language.Solidity,
  },
  accountCodeStorage: {
    address: "0x0000000000000000000000000000000000008002",
    codeName: "AccountCodeStorage",
    lang: Language.Solidity,
  },
  nonceHolder: {
    address: "0x0000000000000000000000000000000000008003",
    codeName: "NonceHolder",
    lang: Language.Solidity,
  },
  knownCodesStorage: {
    address: "0x0000000000000000000000000000000000008004",
    codeName: "KnownCodesStorage",
    lang: Language.Solidity,
  },
  immutableSimulator: {
    address: "0x0000000000000000000000000000000000008005",
    codeName: "ImmutableSimulator",
    lang: Language.Solidity,
  },
  contractDeployer: {
    address: "0x0000000000000000000000000000000000008006",
    codeName: "ContractDeployer",
    lang: Language.Solidity,
  },
  l1Messenger: {
    address: "0x0000000000000000000000000000000000008008",
    codeName: "L1Messenger",
    lang: Language.Solidity,
  },
  msgValueSimulator: {
    address: "0x0000000000000000000000000000000000008009",
    codeName: "MsgValueSimulator",
    lang: Language.Solidity,
  },
  L2BaseToken: {
    address: "0x000000000000000000000000000000000000800a",
    codeName: "L2BaseToken",
    lang: Language.Solidity,
  },
  systemContext: {
    address: "0x000000000000000000000000000000000000800b",
    codeName: "SystemContext",
    lang: Language.Solidity,
  },
  bootloaderUtilities: {
    address: "0x000000000000000000000000000000000000800c",
    codeName: "BootloaderUtilities",
    lang: Language.Solidity,
  },
  eventWriter: {
    address: "0x000000000000000000000000000000000000800d",
    codeName: "EventWriter",
    lang: Language.Yul,
    path: "",
  },
  compressor: {
    address: "0x000000000000000000000000000000000000800e",
    codeName: "Compressor",
    lang: Language.Solidity,
  },
  complexUpgrader: {
    address: "0x000000000000000000000000000000000000800f",
    codeName: "ComplexUpgrader",
    lang: Language.Solidity,
  },
  keccak256: {
    address: "0x0000000000000000000000000000000000008010",
    codeName: "Keccak256",
    lang: Language.Yul,
    path: "precompiles",
  },
  codeOracle: {
    address: "0x0000000000000000000000000000000000008012",
    codeName: "CodeOracle",
    lang: Language.Yul,
    path: "precompiles",
  },
  p256Verify: {
    address: "0x0000000000000000000000000000000000000100",
    codeName: "P256Verify",
    lang: Language.Yul,
    path: "precompiles",
  },
  pubdataChunkPublisher: {
    address: "0x0000000000000000000000000000000000008011",
    codeName: "PubdataChunkPublisher",
    lang: Language.Solidity,
  },
  create2Factory: {
    // This is explicitly a non-system-contract address.
    // We do not use the same address as create2 factories on EVM, since
    // this is a zkEVM create2 factory.
    address: "0x0000000000000000000000000000000000010000",
    codeName: "Create2Factory",
    lang: Language.Solidity,
  },
} as const;

export const EIP712_TX_ID = 113;
export const CHAIN_ID = 270;

// For now, these types are hardcoded, but maybe it will make sense
export const EIP712_DOMAIN = {
  name: "zkSync",
  version: "2",
  chainId: CHAIN_ID,
  // zkSync contract doesn't verify EIP712 signatures.
};

export interface TransactionData {
  txType: BigNumberish;
  from: BigNumberish;
  to: BigNumberish;
  gasLimit: BigNumberish;
  gasPerPubdataByteLimit: BigNumberish;
  gasPrice: BigNumberish;
  // In the future, we might want to add some
  // new fields to the struct. The `txData` struct
  // is to be passed to account and any changes to its structure
  // would mean a breaking change to these accounts. In order to prevent this,
  // we should keep some fields as "reserved".
  // It is also recommended that their length is fixed, since
  // it would allow easier proof integration (in case we will need
  // some special circuit for preprocessing transactions).
  reserved: BigNumberish[];
  data: BytesLike;
  signature: BytesLike;
  // Reserved dynamic type for the future use-case. Using it should be avoided,
  // But it is still here, just in case we want to enable some additional functionality.
  reservedDynamic: BytesLike;
}

export interface EIP712Tx {
  txType: BigNumberish;
  from: BigNumberish;
  to: BigNumberish;
  value: BigNumberish;
  gasLimit: BigNumberish;
  gasPerPubdataByteLimit: BigNumberish;
  gasPrice: BigNumberish;
  nonce: BigNumberish;
  data: BytesLike;
  signature: BytesLike;
}

export type Address = string;

export const EIP712_TX_TYPE = {
  Transaction: [
    { name: "txType", type: "uint8" },
    { name: "to", type: "uint256" },
    { name: "value", type: "uint256" },
    { name: "data", type: "bytes" },
    { name: "gasLimit", type: "uint256" },
    { name: "gasPerPubdataByteLimit", type: "uint256" },
    { name: "gasPrice", type: "uint256" },
    { name: "nonce", type: "uint256" },
  ],
};

export type DynamicType = "bytes" | "bytes32[]";
export type FixedType = "address" | "uint256" | "uint128" | "uint32";
export type FieldType = FixedType | DynamicType;

function isDynamicType(x: FieldType): x is DynamicType {
  return x == "bytes" || x == "bytes32[]";
}

function isFixedType(x: FieldType): x is FixedType {
  return !isDynamicType(x);
}

export const TransactionFields: Record<string, FieldType | FixedType[]> = {
  txType: "uint256",
  from: "address",
  to: "address",
  gasLimit: "uint32",
  gasPerPubdataByteLimit: "uint32",
  maxFeePerGas: "uint256",
  maxPriorityFeePerGas: "uint256",
  paymaster: "address",
  // In the future, we might want to add some
  // new fields to the struct. The `txData` struct
  // is to be passed to account and any changes to its structure
  // would mean a breaking change to these accounts. In order to prevent this,
  // we should keep some fields as "reserved".
  // It is also recommended that their length is fixed, since
  // it would allow easier proof integration (in case we will need
  // some special circuit for preprocessing transactions).
  reserved: Array(6).fill("uint256"),
  data: "bytes",
  signature: "bytes",
  factoryDeps: "bytes32[]",
  paymasterInput: "bytes",
  // Reserved dynamic type for the future use-case. Using it should be avoided,
  // But it is still here, just in case we want to enable some additional functionality.
  reservedDynamic: "bytes",
};

function capitalize(s: string) {
  if (!s.length) {
    return s;
  }
  return `${s[0].toUpperCase()}${s.substring(1)}`;
}

function memPosFromOffset(offset: number) {
  return offset === 0 ? "innerTxDataOffset" : `add(innerTxDataOffset, ${offset})`;
}

function getGetterName(fieldName: string) {
  return `get${capitalize(fieldName)}`;
}

function getPtrGetterName(fieldName: string) {
  return `get${capitalize(fieldName)}Ptr`;
}

function getGetter(fieldName: string, offset: number) {
  const getterName = getGetterName(fieldName);
  const memPos = memPosFromOffset(offset);
  return `
            function ${getterName}(innerTxDataOffset) -> ret {
                ret := mload(${memPos})
            }
    `;
}

function getPtrGetter(fieldName: string, offset: number) {
  const getterName = getPtrGetterName(fieldName);
  const memPos = memPosFromOffset(offset);
  return `
            function ${getterName}(innerTxDataOffset) -> ret {
                ret := mload(${memPos})
                ret := add(innerTxDataOffset, ret)
            }
    `;
}

function getTypeValidationMethodName(type: FieldType) {
  if (type == "bytes32[]") {
    return "validateBytes32Array";
  } else {
    return `validate${capitalize(type)}`;
  }
}

function getBytesLengthGetterName(fieldName: string): string {
  return `get${capitalize(fieldName)}BytesLength`;
}

function getBytesLengthGetter(fieldName: string, type: DynamicType) {
  let lengthToBytes: string;
  if (type == "bytes") {
    lengthToBytes = "lengthToWords(mload(ptr))";
  } else if (type == "bytes32[]") {
    lengthToBytes = "mul(mload(ptr),32)";
  } else {
    throw new Error(`Type ${type} is not supported`);
  }

  const getterName = getBytesLengthGetterName(fieldName);
  return `
            function ${getterName}(innerTxDataOffset) -> ret {
                let ptr := ${getPtrGetterName(fieldName)}(innerTxDataOffset)
                ret := ${lengthToBytes}
            }
    `;
}

function getDataLength(baseLength: number, dynamicFields: [string, DynamicType][]) {
  const ptrAdders = dynamicFields
    .map(([fieldName]) => {
      return `
                ret := add(ret, ${getBytesLengthGetterName(fieldName)}(innerTxDataOffset))`;
    })
    .join("");

  return `
            function getDataLength(innerTxDataOffset) -> ret {
                // To get the length of the txData in bytes, we can simply
                // get the number of fields * 32 + the length of the dynamic types
                // in bytes.
                ret := ${baseLength + dynamicFields.length * 32}

                ${ptrAdders}
            }
    `;
}

function validateFixedSizeField(fieldName: string, type: FixedType): string {
  if (type == "uint256") {
    // There is no validation for uint256
    return "";
  }
  const assertionErrorStr = getEncodingError(fieldName);
  const fieldValue = `${fieldName}Value`;
  return `
                let ${fieldValue} := ${getGetterName(fieldName)}(innerTxDataOffset)
                if iszero(${getTypeValidationMethodName(type)}(${fieldValue})) {
                    assertionError("${assertionErrorStr}")
                }
    `;
}

function getEncodingError(fieldName: string) {
  // Unfortunately we have to keep this not-so-readable name
  // because the maximum length is 32.
  const assertionError = `Encoding ${fieldName}`;

  if (assertionError.length > 32) {
    throw new Error(`Assertion str too long: ${assertionError}`);
  }

  return assertionError;
}

function getValidateTxStructure(
  fixedFieldsChecks: string,
  fixedLenPart: number,
  dynamicFields: [string, DynamicType][]
): string {
  const dynamicChecks = dynamicFields
    .map(([fieldName, type]) => {
      const lengthPos = `${fieldName}LengthPos`;
      const assertionError = getEncodingError(fieldName);
      const validationMethod = getTypeValidationMethodName(type);

      return `
                let ${lengthPos} := ${getPtrGetterName(fieldName)}(innerTxDataOffset)
                if iszero(eq(${lengthPos}, expectedDynamicLenPtr)) {
                    assertionError("${assertionError}")
                }
                expectedDynamicLenPtr := ${validationMethod}(${lengthPos})
        `;
    })
    .join("\n");

  return `
            /// This method checks that the transaction's structure is correct
            /// and tightly packed
            function validateAbiEncoding(innerTxDataOffset) -> ret {
                ${fixedFieldsChecks}

                let expectedDynamicLenPtr := add(innerTxDataOffset, ${fixedLenPart})
                ${dynamicChecks}
            }`;
}

export function getTransactionUtils(): string {
  let result = `///
            /// TransactionData utilities
            ///\n`;

  let innerOffsetBytes = 0;
  let checksStr = "";

  const dynamicFields: [string, DynamicType][] = [];
  for (const [key, value] of Object.entries(TransactionFields)) {
    if (Array.isArray(value)) {
      // We assume that the
      for (let i = 0; i < value.length; i++) {
        const keyName = `${key}${i}`;
        result += getGetter(keyName, innerOffsetBytes);
        checksStr += validateFixedSizeField(keyName, value[i]);
        innerOffsetBytes += 32;
      }
    } else if (isFixedType(value)) {
      result += getGetter(key, innerOffsetBytes);
      checksStr += validateFixedSizeField(key, value);
      innerOffsetBytes += 32;
    } else {
      result += getPtrGetter(key, innerOffsetBytes);
      result += getBytesLengthGetter(key, value);
      dynamicFields.push([key, value]);
      innerOffsetBytes += 32;
    }
  }

  result += getValidateTxStructure(checksStr, innerOffsetBytes, dynamicFields);

  result += getDataLength(innerOffsetBytes, dynamicFields);

  return result;
}

export function getRevertSelector(): string {
  return ethers.utils.keccak256(ethers.utils.toUtf8Bytes("Error(string)")).substring(0, 10);
}

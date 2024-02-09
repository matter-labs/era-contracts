import type { BytesLike } from "ethers";
import { ethers } from "ethers";
import * as fs from "fs";

// eslint-disable-next-line @typescript-eslint/no-var-requires
export const REQUIRED_L2_GAS_PRICE_PER_PUBDATA = require("../../SystemConfig.json").REQUIRED_L2_GAS_PRICE_PER_PUBDATA;

export const L1_TO_L2_ALIAS_OFFSET = "0x1111000000000000000000000000000000001111";
const CREATE2_PREFIX = ethers.utils.solidityKeccak256(["string"], ["zksyncCreate2"]);

const ADDRESS_MODULO = ethers.BigNumber.from(2).pow(160);

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

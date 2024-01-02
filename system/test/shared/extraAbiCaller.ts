import type { BigNumber } from "ethers";
import { ethers } from "hardhat";

// kernel space is required to set the context u128 value
export const EXTRA_ABI_CALLER_ADDRESS = "0x000000000000000000000000000000000000BEEF";
const EXTRA_ABI_REGISTERS_NUMBER = 10;

export function encodeExtraAbiCallerCalldata(
  to: string,
  value: BigNumber,
  extraData: string[],
  calldata: string
): string {
  if (extraData.length > EXTRA_ABI_REGISTERS_NUMBER) throw "Too big extraData length";
  extraData.push(...Array(EXTRA_ABI_REGISTERS_NUMBER - extraData.length).fill(ethers.constants.HashZero));
  const encodedData = ethers.utils.defaultAbiCoder.encode(
    ["address", "uint256", `uint256[${EXTRA_ABI_REGISTERS_NUMBER}]`],
    [to, value, extraData]
  );
  return ethers.utils.hexConcat([encodedData, calldata]);
}

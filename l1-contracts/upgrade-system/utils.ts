/// @dev This method checks if the overrides contain a gasPrice (or maxFeePerGas), if not it will insert
/// the maxFeePerGas
import type { ethers } from "ethers";

export async function insertGasPrice(l1Provider: ethers.Provider, overrides: ethers.Overrides) {
  if (!overrides.gasPrice && !overrides.maxFeePerGas) {
    const l1FeeData = await l1Provider.getFeeData();

    const baseFee = l1FeeData.gasPrice;

    // ethers.js by default uses multiplcation by 2, but since the price for the L2 part
    // will depend on the L1 part, doubling base fee is typically too much.
    const maxFeePerGas = (baseFee*3n)/2n + l1FeeData.maxPriorityFeePerGas;

    overrides.maxFeePerGas = maxFeePerGas;
    overrides.maxPriorityFeePerGas = l1FeeData.maxPriorityFeePerGas;
  }
}

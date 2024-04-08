/// @dev This method checks if the overrides contain a gasPrice (or maxFeePerGas), if not it will insert
/// the maxFeePerGas
import type { ethers } from "ethers";

export async function insertGasPrice(l1Provider: ethers.providers.Provider, overrides: ethers.PayableOverrides) {
  if (!overrides.gasPrice && !overrides.maxFeePerGas) {
    const l1FeeData = await l1Provider.getFeeData();

    // Sometimes baseFeePerGas is not available, so we use gasPrice instead.
    const baseFee = l1FeeData.lastBaseFeePerGas || l1FeeData.gasPrice;

    // ethers.js by default uses multiplication by 2, but since the price for the L2 part
    // will depend on the L1 part, doubling base fee is typically too much.
    const maxFeePerGas = baseFee.mul(3).div(2).add(l1FeeData.maxPriorityFeePerGas);

    overrides.maxFeePerGas = maxFeePerGas;
    overrides.maxPriorityFeePerGas = l1FeeData.maxPriorityFeePerGas;
  }
}

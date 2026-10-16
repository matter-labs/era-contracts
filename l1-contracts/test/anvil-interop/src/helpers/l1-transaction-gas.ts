import { ethers } from "ethers";
import { ETHEREUM_L1_TX_GAS_LIMIT } from "../core/const";

export type L1TransactionGasContext = {
  phase: "prepare" | "governance" | "chain-upgrade";
  bundle: string;
  index: number;
  target: string;
};

export type L1TransactionGasRecord = L1TransactionGasContext & {
  transactionHash: string;
  gasLimit: number;
  gasUsed: number;
};

type GasReceipt = Pick<ethers.providers.TransactionReceipt, "status" | "transactionHash" | "gasUsed">;

export function checkL1TransactionGas(
  receipt: GasReceipt,
  gasLimit: ethers.BigNumberish,
  context: L1TransactionGasContext
): L1TransactionGasRecord {
  const label = `${context.phase} ${context.bundle} tx ${context.index} (to ${context.target})`;
  if (receipt.status !== 1) {
    throw new Error(`${label}: transaction ${receipt.transactionHash} did not succeed`);
  }
  const declared = ethers.BigNumber.from(gasLimit);
  if (declared.gt(ETHEREUM_L1_TX_GAS_LIMIT)) {
    throw new Error(`${label}: gas limit ${declared} exceeds Ethereum L1 cap ${ETHEREUM_L1_TX_GAS_LIMIT}`);
  }
  if (receipt.gasUsed.gt(ETHEREUM_L1_TX_GAS_LIMIT)) {
    throw new Error(`${label}: gas used ${receipt.gasUsed} exceeds Ethereum L1 cap ${ETHEREUM_L1_TX_GAS_LIMIT}`);
  }
  return {
    ...context,
    transactionHash: receipt.transactionHash,
    gasLimit: declared.toNumber(),
    gasUsed: receipt.gasUsed.toNumber(),
  };
}

export function recordL1TransactionGas(
  receipt: GasReceipt,
  gasLimit: ethers.BigNumberish,
  context: L1TransactionGasContext
): void {
  const record = checkL1TransactionGas(receipt, gasLimit, context);
  console.log(`  L1 transaction gas: ${JSON.stringify(record)}`);
}

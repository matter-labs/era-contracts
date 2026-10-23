import { ethers } from "ethers";
import { ETHEREUM_L1_TX_GAS_LIMIT, REFUND_COUNTER_TRACER } from "../core/const";
import type { CallFrame, GlamsterdamGas, PrestateDiff } from "../core/glamsterdam-gas";
import { L1_GAS_RULES, glamsterdamGas, glamsterdamGasViolations, maxCallDepth } from "../core/glamsterdam-gas";

/** Gas overrides for an L1 tx: `osakaGasLimit` under "osaka", ethers' own estimate under "amsterdam". */
export function l1GasOverrides(osakaGasLimit: ethers.BigNumberish): { gasLimit?: ethers.BigNumberish } {
  return L1_GAS_RULES === "amsterdam" ? {} : { gasLimit: osakaGasLimit };
}

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

function gasLabel(context: L1TransactionGasContext): string {
  return `${context.phase} ${context.bundle} tx ${context.index} (to ${context.target})`;
}

export function checkL1TransactionGas(
  receipt: GasReceipt,
  gasLimit: ethers.BigNumberish,
  context: L1TransactionGasContext
): L1TransactionGasRecord {
  const label = gasLabel(context);
  if (receipt.status !== 1) {
    throw new Error(`${label}: transaction ${receipt.transactionHash} did not succeed`);
  }
  const declared = ethers.BigNumber.from(gasLimit);
  if (L1_GAS_RULES === "osaka" && declared.gt(ETHEREUM_L1_TX_GAS_LIMIT)) {
    throw new Error(`${label}: gas limit ${declared} exceeds Ethereum L1 cap ${ETHEREUM_L1_TX_GAS_LIMIT}`);
  }
  if (L1_GAS_RULES === "osaka" && receipt.gasUsed.gt(ETHEREUM_L1_TX_GAS_LIMIT)) {
    throw new Error(`${label}: gas used ${receipt.gasUsed} exceeds Ethereum L1 cap ${ETHEREUM_L1_TX_GAS_LIMIT}`);
  }
  return {
    ...context,
    transactionHash: receipt.transactionHash,
    gasLimit: declared.toNumber(),
    gasUsed: receipt.gasUsed.toNumber(),
  };
}

async function measureGlamsterdamGas(
  provider: ethers.providers.JsonRpcProvider,
  receipt: ethers.providers.TransactionReceipt
): Promise<GlamsterdamGas> {
  const hash = receipt.transactionHash;
  const tx = await provider.send("eth_getTransactionByHash", [hash]);
  const block = await provider.send("eth_getBlockByNumber", [ethers.utils.hexValue(receipt.blockNumber), false]);
  const diff: PrestateDiff = await provider.send("debug_traceTransaction", [
    hash,
    { tracer: "prestateTracer", tracerConfig: { diffMode: true } },
  ]);
  const refundCounter = Number(
    (await provider.send("debug_traceTransaction", [hash, { tracer: REFUND_COUNTER_TRACER }])) ?? 0
  );
  const calls: CallFrame = await provider.send("debug_traceTransaction", [hash, { tracer: "callTracer" }]);
  return glamsterdamGas({
    diff,
    miner: block.miner ?? "",
    blockGasLimit: ethers.BigNumber.from(block.gasLimit).toNumber(),
    gasUsed: receipt.gasUsed.toNumber(),
    refundCounter,
    callDepth: maxCallDepth(calls),
    tx: { from: tx.from, to: tx.to, value: tx.value, data: tx.input },
  });
}

/**
 * Check and log one L1 transaction (`L1 transaction gas: {json}`). Under "amsterdam" the record also carries the
 * transaction's Glamsterdam gas split, read from the node, and fails when it breaks a Glamsterdam limit.
 */
export async function recordL1TransactionGas(
  provider: ethers.providers.JsonRpcProvider,
  receipt: ethers.providers.TransactionReceipt,
  gasLimit: ethers.BigNumberish,
  context: L1TransactionGasContext
): Promise<void> {
  const record = checkL1TransactionGas(receipt, gasLimit, context);
  if (L1_GAS_RULES === "osaka") {
    console.log(`  L1 transaction gas: ${JSON.stringify(record)}`);
    return;
  }
  const gas = await measureGlamsterdamGas(provider, receipt);
  console.log(`  L1 transaction gas: ${JSON.stringify({ ...record, ...gas })}`);
  const violations = glamsterdamGasViolations(gas);
  if (violations.length > 0) {
    throw new Error(`${gasLabel(context)}: ${violations.join("; ")} (transaction ${receipt.transactionHash})`);
  }
}

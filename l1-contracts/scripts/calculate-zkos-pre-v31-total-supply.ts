#!/usr/bin/env ts-node
/**
 * Calculates the pre-v31 base-token total supply for a ZKsync OS chain.
 *
 * This is the value expected by AdminFacet.setZKsyncOSPreV31TotalSupply().
 *
 * Formula used by the v31 asset-tracker code:
 *
 *   preV31TotalSupply = totalSuccessfulDepositsFromL1 - totalWithdrawalsToL1
 *
 * For ZKsync OS chains before v31:
 *   - withdrawals are observable as L2BaseToken.Withdrawal logs at 0x...800a;
 *   - successful deposits are L1 NewPriorityRequest logs whose L2 priority tx
 *     receipt exists, succeeded, and landed before the v31 L2 boundary.
 *
 * The deposited amount is L2CanonicalTransaction.reserved[0], i.e. mintValue.
 *
 * Example for chain 2702 stage:
 *
 *   yarn ts-node scripts/calculate-zkos-pre-v31-total-supply.ts \
 *     --chain-id 2702 \
 *     --bridgehub 0x236D1c3Ff32Bd0Ca26b72Af287E895627c0478cE \
 *     --l1-rpc "$SEPOLIA_RPC" \
 *     --l2-rpc https://zksync-os-stage.zksync.dev/ \
 *     --upgrade-l1-tx 0xfc13268826342bd6f82baf7ade63ef6dc8cd6b4dc221744d6dc23d09d1089c0c
 */

import { ethers } from "ethers";
import { Command } from "commander";

const DEFAULT_BLOCK_STEP = 10_000;
const DEFAULT_RECEIPT_CONCURRENCY = 20;

const L2_BASE_TOKEN_SYSTEM_CONTRACT = "0x000000000000000000000000000000000000800a";

const BRIDGEHUB_ABI = ["function getZKChain(uint256 _chainId) view returns (address)"];

const MAILBOX_EVENTS_ABI = [
  "event NewPriorityRequest(uint256 txId, bytes32 txHash, uint64 expirationTimestamp, tuple(uint256 txType, uint256 from, uint256 to, uint256 gasLimit, uint256 gasPerPubdataByteLimit, uint256 maxFeePerGas, uint256 maxPriorityFeePerGas, uint256 paymaster, uint256 nonce, uint256 value, uint256[4] reserved, bytes data, bytes signature, uint256[] factoryDeps, bytes paymasterInput, bytes reservedDynamic) transaction, bytes[] factoryDeps)",
];

const L2_BASE_TOKEN_EVENTS_ABI = [
  "event Withdrawal(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount)",
  "event WithdrawalWithMessage(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount, bytes _additionalData)",
];

interface ScanInput {
  provider: ethers.providers.JsonRpcProvider;
  fromBlock: number;
  toBlock: number;
  blockStep: number;
  address: string;
  topics: (string | null)[];
  label: string;
}

interface DepositCandidate {
  txHash: string;
  mintValue: ethers.BigNumber;
}

interface ReceiptStats {
  missingReceipt: number;
  failedReceipt: number;
  afterBoundary: number;
  successfulBeforeBoundary: number;
}

function parseNonNegativeInt(value: string): number {
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0) {
    throw new Error(`Expected a non-negative integer, got: ${value}`);
  }
  return parsed;
}

function parsePositiveInt(value: string): number {
  const parsed = parseNonNegativeInt(value);
  if (parsed === 0) {
    throw new Error(`Expected a positive integer, got: ${value}`);
  }
  return parsed;
}

function hexBlock(block: number): string {
  return `0x${block.toString(16)}`;
}

function formatAmount(value: ethers.BigNumber): string {
  return `${value.toString()} (${ethers.utils.formatEther(value)} assuming 18 decimals)`;
}

function formatUtcDate(timestamp: number): string {
  return new Date(timestamp * 1000).toISOString().replace("T", " ").replace(".000Z", " UTC");
}

async function binarySearchFirstCodeBlock(
  provider: ethers.providers.JsonRpcProvider,
  address: string,
  lo: number,
  hi: number
): Promise<number> {
  const codeAtHi = await provider.getCode(address, hi);
  if (codeAtHi === "0x") {
    throw new Error(`Address ${address} has no code at block ${hi}`);
  }

  const codeAtLo = await provider.getCode(address, lo);
  if (codeAtLo !== "0x") {
    return lo;
  }

  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    const code = await provider.getCode(address, mid);
    if (code !== "0x") {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
}

async function getLogsPaginated({
  provider,
  fromBlock,
  toBlock,
  blockStep,
  address,
  topics,
  label,
}: ScanInput): Promise<ethers.providers.Log[]> {
  const logs: ethers.providers.Log[] = [];
  let cursor = fromBlock;
  let chunks = 0;

  while (cursor <= toBlock) {
    const end = Math.min(cursor + blockStep - 1, toBlock);
    const chunk = await provider.getLogs({
      address,
      topics,
      fromBlock: cursor,
      toBlock: end,
    });
    logs.push(...chunk);

    chunks += 1;
    if (chunks % 25 === 0) {
      console.log(`  ${label}: scanned through block ${end}, logs=${logs.length}`);
    }

    cursor = end + 1;
  }

  return logs;
}

async function getZkChainAddress(
  provider: ethers.providers.JsonRpcProvider,
  bridgehubAddress: string,
  chainId: number
): Promise<string> {
  const bridgehub = new ethers.Contract(bridgehubAddress, BRIDGEHUB_ABI, provider);
  const zkChain = await bridgehub.getZKChain(chainId);
  if (zkChain === ethers.constants.AddressZero) {
    throw new Error(`Bridgehub ${bridgehubAddress} returned zero address for chain ${chainId}`);
  }
  return ethers.utils.getAddress(zkChain);
}

async function resolveToL2Block(
  provider: ethers.providers.JsonRpcProvider,
  explicitToL2Block: number | undefined
): Promise<{ toL2Block: number; firstV31L2Block: number | null }> {
  if (explicitToL2Block !== undefined) {
    return { toL2Block: explicitToL2Block, firstV31L2Block: explicitToL2Block + 1 };
  }

  const latest = await provider.getBlockNumber();
  const firstV31L2Block = await binarySearchFirstCodeBlock(provider, L2_BASE_TOKEN_SYSTEM_CONTRACT, 0, latest);
  if (firstV31L2Block === 0) {
    throw new Error(`${L2_BASE_TOKEN_SYSTEM_CONTRACT} already has code at L2 block 0; pass --to-l2-block explicitly`);
  }

  return { toL2Block: firstV31L2Block - 1, firstV31L2Block };
}

async function resolveToL1Block(
  provider: ethers.providers.JsonRpcProvider,
  explicitToL1Block: number | undefined,
  upgradeL1Tx: string | undefined
): Promise<number> {
  if (explicitToL1Block !== undefined) {
    return explicitToL1Block;
  }

  if (upgradeL1Tx) {
    const receipt = await provider.getTransactionReceipt(upgradeL1Tx);
    if (!receipt) {
      throw new Error(`No L1 receipt found for upgrade tx ${upgradeL1Tx}`);
    }
    return receipt.blockNumber;
  }

  return provider.getBlockNumber();
}

async function sumWithdrawalEvent({
  provider,
  toL2Block,
  blockStep,
  eventName,
}: {
  provider: ethers.providers.JsonRpcProvider;
  toL2Block: number;
  blockStep: number;
  eventName: "Withdrawal" | "WithdrawalWithMessage";
}): Promise<{ total: ethers.BigNumber; logs: number }> {
  const iface = new ethers.utils.Interface(L2_BASE_TOKEN_EVENTS_ABI);
  const topic = iface.getEventTopic(eventName);

  const logs = await getLogsPaginated({
    provider,
    fromBlock: 0,
    toBlock: toL2Block,
    blockStep,
    address: L2_BASE_TOKEN_SYSTEM_CONTRACT,
    topics: [topic],
    label: `L2 ${eventName}`,
  });

  let total = ethers.constants.Zero;
  for (const log of logs) {
    const parsed = iface.parseLog(log);
    total = total.add(parsed.args._amount);
  }

  return { total, logs: logs.length };
}

async function sumWithdrawals({
  provider,
  toL2Block,
  blockStep,
}: {
  provider: ethers.providers.JsonRpcProvider;
  toL2Block: number;
  blockStep: number;
}): Promise<{ total: ethers.BigNumber; withdrawalLogs: number; withdrawalWithMessageLogs: number }> {
  const withdrawal = await sumWithdrawalEvent({
    provider,
    toL2Block,
    blockStep,
    eventName: "Withdrawal",
  });
  const withdrawalWithMessage = await sumWithdrawalEvent({
    provider,
    toL2Block,
    blockStep,
    eventName: "WithdrawalWithMessage",
  });

  return {
    total: withdrawal.total.add(withdrawalWithMessage.total),
    withdrawalLogs: withdrawal.logs,
    withdrawalWithMessageLogs: withdrawalWithMessage.logs,
  };
}

async function collectDepositCandidates({
  provider,
  diamondProxy,
  fromL1Block,
  toL1Block,
  blockStep,
}: {
  provider: ethers.providers.JsonRpcProvider;
  diamondProxy: string;
  fromL1Block: number;
  toL1Block: number;
  blockStep: number;
}): Promise<{ deposits: DepositCandidate[]; logs: number; zeroMintValue: number }> {
  const iface = new ethers.utils.Interface(MAILBOX_EVENTS_ABI);
  const topic = iface.getEventTopic("NewPriorityRequest");

  const logs = await getLogsPaginated({
    provider,
    fromBlock: fromL1Block,
    toBlock: toL1Block,
    blockStep,
    address: diamondProxy,
    topics: [topic],
    label: "L1 NewPriorityRequest",
  });

  const deposits: DepositCandidate[] = [];
  let zeroMintValue = 0;

  for (const log of logs) {
    const parsed = iface.parseLog(log);
    const mintValue = parsed.args.transaction.reserved[0] as ethers.BigNumber;
    if (mintValue.isZero()) {
      zeroMintValue += 1;
      continue;
    }

    deposits.push({
      txHash: parsed.args.txHash,
      mintValue,
    });
  }

  return { deposits, logs: logs.length, zeroMintValue };
}

async function mapLimit<T, U>(items: T[], concurrency: number, fn: (item: T) => Promise<U>): Promise<U[]> {
  const results = new Array<U>(items.length);
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (true) {
      const index = nextIndex;
      nextIndex += 1;
      if (index >= items.length) {
        return;
      }
      results[index] = await fn(items[index]);
    }
  }

  const workers = Array.from({ length: Math.min(concurrency, items.length) }, () => worker());
  await Promise.all(workers);
  return results;
}

async function getReceiptWithRetry(
  provider: ethers.providers.JsonRpcProvider,
  txHash: string
): Promise<ethers.providers.TransactionReceipt | null> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= 3; attempt += 1) {
    try {
      return await provider.getTransactionReceipt(txHash);
    } catch (err) {
      lastErr = err;
      await new Promise((resolve) => setTimeout(resolve, 250 * attempt));
    }
  }
  throw lastErr;
}

async function sumSuccessfulDeposits({
  provider,
  deposits,
  toL2Block,
  receiptConcurrency,
}: {
  provider: ethers.providers.JsonRpcProvider;
  deposits: DepositCandidate[];
  toL2Block: number;
  receiptConcurrency: number;
}): Promise<{ total: ethers.BigNumber; stats: ReceiptStats }> {
  const stats = {
    missingReceipt: 0,
    failedReceipt: 0,
    afterBoundary: 0,
    successfulBeforeBoundary: 0,
  };

  let checked = 0;
  let total = ethers.constants.Zero;

  const results = await mapLimit(deposits, receiptConcurrency, async (deposit) => {
    const receipt = await getReceiptWithRetry(provider, deposit.txHash);
    checked += 1;
    if (checked % 500 === 0) {
      console.log(`  L2 receipts: checked ${checked}/${deposits.length}`);
    }
    return { deposit, receipt };
  });

  for (const { deposit, receipt } of results) {
    if (!receipt) {
      stats.missingReceipt += 1;
      continue;
    }
    if (receipt.blockNumber > toL2Block) {
      stats.afterBoundary += 1;
      continue;
    }
    if (receipt.status !== 1) {
      stats.failedReceipt += 1;
      continue;
    }

    stats.successfulBeforeBoundary += 1;
    total = total.add(deposit.mintValue);
  }

  return { total, stats };
}

async function main(): Promise<void> {
  const program = new Command();

  program
    .name("calculate-zkos-pre-v31-total-supply")
    .description("Calculate the value for AdminFacet.setZKsyncOSPreV31TotalSupply().")
    .requiredOption("--chain-id <n>", "ZK chain id", parsePositiveInt)
    .requiredOption("--bridgehub <address>", "L1 Bridgehub address")
    .requiredOption("--l1-rpc <url>", "L1 RPC URL")
    .requiredOption("--l2-rpc <url>", "L2 RPC URL")
    .option("--upgrade-l1-tx <hash>", "L1 chain-upgrade execution tx; used only to cap the L1 log scan")
    .option("--from-l1-block <n>", "Starting L1 block for NewPriorityRequest scan", parseNonNegativeInt)
    .option("--to-l1-block <n>", "Ending L1 block for NewPriorityRequest scan", parseNonNegativeInt)
    .option(
      "--to-l2-block <n>",
      "Last pre-v31 L2 block; defaults to first 0x...800a code block minus one",
      parseNonNegativeInt
    )
    .option(
      "--block-step <n>",
      `eth_getLogs block window (default ${DEFAULT_BLOCK_STEP})`,
      parsePositiveInt,
      DEFAULT_BLOCK_STEP
    )
    .option(
      "--receipt-concurrency <n>",
      `Concurrent L2 receipt lookups (default ${DEFAULT_RECEIPT_CONCURRENCY})`,
      parsePositiveInt,
      DEFAULT_RECEIPT_CONCURRENCY
    );

  const opts = program.parse(process.argv).opts<{
    chainId: number;
    bridgehub: string;
    l1Rpc: string;
    l2Rpc: string;
    upgradeL1Tx?: string;
    fromL1Block?: number;
    toL1Block?: number;
    toL2Block?: number;
    blockStep: number;
    receiptConcurrency: number;
  }>();

  const l1Provider = new ethers.providers.JsonRpcProvider(opts.l1Rpc);
  const l2Provider = new ethers.providers.JsonRpcProvider(opts.l2Rpc);
  const bridgehub = ethers.utils.getAddress(opts.bridgehub);

  const diamondProxy = await getZkChainAddress(l1Provider, bridgehub, opts.chainId);
  const toL1Block = await resolveToL1Block(l1Provider, opts.toL1Block, opts.upgradeL1Tx);
  const fromL1Block = opts.fromL1Block ?? (await binarySearchFirstCodeBlock(l1Provider, diamondProxy, 0, toL1Block));
  const { toL2Block, firstV31L2Block } = await resolveToL2Block(l2Provider, opts.toL2Block);
  const cutoffL2Block = await l2Provider.getBlock(toL2Block);
  if (!cutoffL2Block) {
    throw new Error(`No L2 block found for cutoff block ${toL2Block}`);
  }

  if (fromL1Block > toL1Block) {
    throw new Error(`Invalid L1 block range: ${fromL1Block} > ${toL1Block}`);
  }

  console.log("Calculation plan:");
  console.log(`  chain id:                 ${opts.chainId}`);
  console.log(`  bridgehub:                ${bridgehub}`);
  console.log(`  diamond proxy:            ${diamondProxy}`);
  console.log(`  L1 block range:           [${fromL1Block}, ${toL1Block}]`);
  console.log(
    `  L2 pre-v31 range:         [0, ${toL2Block}]` +
      (firstV31L2Block === null ? "" : ` (first v31 block: ${firstV31L2Block})`)
  );
  console.log(`  cutoff date:              ${formatUtcDate(cutoffL2Block.timestamp)} (L2 block ${toL2Block})`);
  console.log(`  getLogs block step:       ${opts.blockStep}`);
  console.log(`  receipt concurrency:      ${opts.receiptConcurrency}`);

  console.log("\n[1/3] Summing L2 withdrawals...");
  const withdrawals = await sumWithdrawals({
    provider: l2Provider,
    toL2Block,
    blockStep: opts.blockStep,
  });
  console.log(`  Withdrawal logs:          ${withdrawals.withdrawalLogs}`);
  console.log(`  WithdrawalWithMessage:    ${withdrawals.withdrawalWithMessageLogs}`);
  console.log(`  totalWithdrawalsToL1:     ${formatAmount(withdrawals.total)}`);

  console.log("\n[2/3] Reading L1 priority requests...");
  const candidates = await collectDepositCandidates({
    provider: l1Provider,
    diamondProxy,
    fromL1Block,
    toL1Block,
    blockStep: opts.blockStep,
  });
  console.log(`  NewPriorityRequest logs:  ${candidates.logs}`);
  console.log(`  non-zero mintValue logs:  ${candidates.deposits.length}`);
  console.log(`  zero mintValue logs:      ${candidates.zeroMintValue}`);

  console.log("\n[3/3] Checking L2 priority transaction receipts...");
  const deposits = await sumSuccessfulDeposits({
    provider: l2Provider,
    deposits: candidates.deposits,
    toL2Block,
    receiptConcurrency: opts.receiptConcurrency,
  });
  console.log(`  successful before v31:    ${deposits.stats.successfulBeforeBoundary}`);
  console.log(`  failed before v31:        ${deposits.stats.failedReceipt}`);
  console.log(`  landed after boundary:    ${deposits.stats.afterBoundary}`);
  console.log(`  missing L2 receipt:       ${deposits.stats.missingReceipt}`);
  console.log(`  totalSuccessfulDeposits:  ${formatAmount(deposits.total)}`);

  if (deposits.total.lt(withdrawals.total)) {
    throw new Error(
      `Computed deposits < withdrawals: deposits=${deposits.total.toString()} withdrawals=${withdrawals.total.toString()}`
    );
  }

  const preV31TotalSupply = deposits.total.sub(withdrawals.total);
  console.log("\nResult:");
  console.log(`  cutoff date:              ${formatUtcDate(cutoffL2Block.timestamp)} (L2 block ${toL2Block})`);
  console.log(`  total deposited:          ${formatAmount(deposits.total)}`);
  console.log(`  total withdrawn:          ${formatAmount(withdrawals.total)}`);
  console.log(`  preV31TotalSupply:        ${formatAmount(preV31TotalSupply)}`);
  console.log(`  raw uint256:              ${preV31TotalSupply.toString()}`);
}

main().catch((err) => {
  console.error(err instanceof Error ? (err.stack ?? err.message) : err);
  process.exit(1);
});

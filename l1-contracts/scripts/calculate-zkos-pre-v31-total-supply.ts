#!/usr/bin/env ts-node
/**
 * Calculates the pre-v31 base-token total supply for a ZKsync OS chain.
 *
 * This is the value expected by AdminFacet.setZKsyncOSPreV31TotalSupply(). It can be set only once
 * (AdminFacet and L2BaseTokenZKOS both revert with BaseTokenPreV31TotalSupplyAlreadySet afterwards),
 * so the script refuses to print a number unless its inputs are complete and consistent.
 *
 * Formula used by the v31 asset-tracker code:
 *
 *   preV31TotalSupply = totalExecutedDepositsFromL1 - totalWithdrawalsToL1
 *
 * The pre-v31 boundary:
 *   - The chain's v31 upgrade lands in L1 block U, the first block at which the diamond reports
 *     protocol v0.31 or later. The upgrade requires every committed batch to be executed
 *     (SettlementLayerV31UpgradeBase: NotAllBatchesExecuted).
 *   - On L2 the upgrade tx is the first tx of its block (zksync-os bootloader: UpgradeTxNotFirst), and
 *     that block is the first block of its batch (the zksync-os batch public input takes
 *     upgrade_tx_hash from the first block and requires it to be zero for the others). The L1
 *     Committer expects the upgrade tx in the first batch committed after the upgrade.
 *   - So the pre-v31 L2 blocks are exactly the blocks of the batches executed by block U, and the
 *     priority txs they processed are exactly txId < k, with k = getFirstUnprocessedPriorityTx() at U.
 *
 * Deposits are the sum of L2CanonicalTransaction.reserved[0] (mintValue) over the NewPriorityRequest
 * logs with txId < k. The bootloader mints reserved[0] for every priority tx it processes, whatever
 * its status: the fee goes to the operator and, on revert, the rest goes to the refund recipient
 * instead of the target. A reverted deposit therefore still adds its full mintValue to the L2 supply
 * (Era behaves the same, so Era's L2BaseToken.totalSupply() includes them too).
 *
 * Withdrawals are the sum of the L2BaseToken Withdrawal / WithdrawalWithMessage logs at 0x...800a in
 * the pre-v31 L2 blocks.
 *
 * Checks (any failure aborts before a value is printed):
 *   - eth_chainId of --l2-rpc equals --chain-id, eth_chainId of --l1-rpc equals the bridgehub's
 *     L1_CHAIN_ID(), and the diamond reports --chain-id.
 *   - The NewPriorityRequest logs up to block U carry the txIds 0..N-1 exactly once each, with
 *     N = getTotalPriorityTxs() at U. Some RPCs silently return no logs for old ranges.
 *   - At U, getL2SystemContractsUpgradeTxHash() is non-zero, so the upgrade batch was not executed in
 *     block U and k is still the pre-upgrade value, and the chain settles on L1.
 *   - On L2 that upgrade tx succeeded as tx 0 of its block, and 0x...800a has code from that block on
 *     and none before it.
 *   - Every txId < k has an L2 receipt in a pre-v31 block, in txId order; no txId >= k has one.
 *
 * The script refuses to run for:
 *   - Chains with zksync-os v0.0.x history (8022833, 42111). v0.0.x burned withdrawn base token
 *     without emitting Withdrawal events, so the result would be overstated. Chain data does not tell
 *     which blocks ran v0.0.x (zksync-os-server keeps an explicit list for the same reason), so this
 *     script keeps the same list.
 *   - Era chains (they track L2BaseToken.totalSupply() natively), chains created at protocol v0.31 or
 *     later (no pre-v31 history), and chains that settled on a Gateway at the v31 upgrade.
 * L2 withdrawal logs have no on-chain counter to check against, so point --l2-rpc at the chain's own
 * node with full history. The receipt cross-check fails on nodes that lack the pre-v31 history.
 *
 * Ordering, ideally with no gap between the steps:
 *   1. The chain is upgraded to v31 on L1.
 *   2. The L2 upgrade tx is executed on L2. This script needs its receipt.
 *   3. Run this script.
 *   4. Set the value with `protocol-ops chain set-zkos-pre-v31-total-supply`.
 * Until step 4 is executed on L2, L2BaseTokenZKOS.totalSupply() reverts
 * (BaseTokenPreV31TotalSupplyNotSet) and L2AssetTracker.initiateL1ToGatewayMigrationOnL2 reverts for
 * every asset (BaseTokenTotalSupplyBackfillRequired), so no token balance can migrate to Gateway.
 *
 * Prerequisites: run `forge build` in l1-contracts/ (the ABIs are read from out/). --l1-rpc must serve
 * historical state (archive node).
 *
 * Fetched logs and receipts are cached under script-out/ (git-ignored), keyed by L1 chain id, chain id,
 * diamond and block range. Use --cache-dir to move the cache or --no-cache to disable it.
 *
 * Example for testnet chain 579029, whose result matches the value set on chain
 * (`$L1_RPC_URL` must be a Sepolia archive node):
 *
 *   yarn ts-node scripts/calculate-zkos-pre-v31-total-supply.ts \
 *     --chain-id 579029 \
 *     --bridgehub 0xc4FD2580C3487bba18D63f50301020132342fdbD \
 *     --l1-rpc "$L1_RPC_URL" \
 *     --l2-rpc https://zksync-os-testnet-xsolla.zksync.dev
 */

import { ethers } from "ethers";
import { Command } from "commander";
import * as fs from "fs";
import * as path from "path";
import { SCRIPT_OUT_DIR, loadAbiFromFoundryOutput } from "./upgrade-script-utils";

const DEFAULT_BLOCK_STEP = 10_000;
const DEFAULT_RECEIPT_CONCURRENCY = 20;
const DEFAULT_CACHE_DIR = path.join(SCRIPT_OUT_DIR, "zkos-pre-v31-total-supply-cache");

/** Bump whenever the cached records or the scanned events change. */
const CACHE_FORMAT_VERSION = 2;
const CACHE_SAVE_EVERY_CHUNKS = 25;
const PROGRESS_LOG_EVERY_CHUNKS = 25;
const PROGRESS_LOG_EVERY_RECEIPTS = 500;
const RPC_RETRY_ATTEMPTS = 6;
const RPC_RETRY_BASE_DELAY_MS = 500;
const MAX_REPORTED_ISSUES = 10;

const L2_BASE_TOKEN_SYSTEM_CONTRACT = "0x000000000000000000000000000000000000800a";

/** Same as SEMVER_MINOR_OFFSET and SEMVER_MAJOR_OFFSET in contracts/common/libraries/SemVer.sol. */
const SEMVER_MINOR_OFFSET = 32;
const SEMVER_MAJOR_OFFSET = 64;
/** Minor protocol version of the upgrade that introduced the pre-v31 total supply backfill. */
const V31_PROTOCOL_MINOR_VERSION = 31;

/**
 * Chains whose early blocks ran zksync-os v0.0.x, which emitted no Withdrawal events.
 * Same chains as PROTOCOL_VERSION_ACTIVATION_BLOCKS in zksync-os-server (node/bin/src/config/mod.rs).
 */
const LEGACY_ZKSYNC_OS_CHAIN_IDS: ReadonlySet<number> = new Set([8022833, 42111]);

interface Options {
  chainId: number;
  bridgehub: string;
  l1Rpc: string;
  l2Rpc: string;
  upgradeL1Tx?: string;
  fromL1Block?: number;
  blockStep: number;
  receiptConcurrency: number;
  cacheDir: string;
  cache: boolean;
}

interface PriorityRequestRecord {
  txId: number;
  /** Canonical L2 tx hash, which is also the hash of the priority tx on L2. */
  txHash: string;
  /** L2CanonicalTransaction.reserved[0], decimal. */
  mintValue: string;
  l1BlockNumber: number;
}

interface WithdrawalRecord {
  l2BlockNumber: number;
  event: string;
  /** Decimal. */
  amount: string;
}

interface ReceiptRecord {
  blockNumber: number;
  transactionIndex: number;
  status: number;
}

interface LogScanCache<T> {
  address: string;
  topics: (string | string[])[];
  /** Keyed by `${fromBlock}-${toBlock}`. */
  chunks: Record<string, T[]>;
}

interface SupplyCache {
  formatVersion: number;
  l1ChainId: number;
  chainId: number;
  diamond: string;
  priorityRequests?: LogScanCache<PriorityRequestRecord>;
  withdrawals?: LogScanCache<WithdrawalRecord>;
  /** Keyed by L2 tx hash. Only receipts that exist are cached. */
  receipts: Record<string, ReceiptRecord>;
}

interface CacheHandle {
  data: SupplyCache;
  /** null when the cache is disabled. */
  filePath: string | null;
}

interface L1Boundary {
  upgradeL1Block: number;
  /** N: getTotalPriorityTxs() at the upgrade block. */
  totalPriorityTxs: number;
  /** k: getFirstUnprocessedPriorityTx() at the upgrade block. */
  firstUnprocessedPriorityTx: number;
  totalBatchesExecuted: number;
  l2UpgradeTxHash: string;
}

interface L2Boundary {
  firstV31L2Block: number;
  lastPreV31L2Block: number;
  cutoffTimestamp: number;
}

interface ReceiptStats {
  /** Executed before the boundary with status 1. Counted. */
  succeededBeforeBoundary: number;
  /** Executed before the boundary with status 0. Counted too: the mintValue was still minted. */
  revertedBeforeBoundary: number;
  /** txId >= k, executed after the boundary. Not counted. */
  executedAfterBoundary: number;
  /** txId >= k, no L2 receipt yet. Not counted. */
  notExecutedYet: number;
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

function formatAmount(value: ethers.BigNumber): string {
  return `${value.toString()} (${ethers.utils.formatEther(value)} assuming 18 decimals)`;
}

function formatUtcDate(timestamp: number): string {
  return new Date(timestamp * 1000).toISOString().replace("T", " ").replace(".000Z", " UTC");
}

function formatIssues(issues: string[]): string {
  const shown = issues.slice(0, MAX_REPORTED_ISSUES).map((issue) => `  - ${issue}`);
  if (issues.length > MAX_REPORTED_ISSUES) {
    shown.push(`  ... and ${issues.length - MAX_REPORTED_ISSUES} more`);
  }
  return shown.join("\n");
}

function errorMessage(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
}

/** RPC URLs can embed API keys, so they are kept out of the error output. */
function redactRpcUrls(message: string, rpcUrls: string[]): string {
  return rpcUrls.reduce((redacted, url, index) => redacted.split(url).join(`<rpc-url-${index + 1}>`), message);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/** Retries every error: ethers reports some transient RPC errors (e.g. rate limits on eth_call) as reverts. */
async function withRetry<T>(label: string, fn: () => Promise<T>): Promise<T> {
  let lastErr: unknown;
  for (let attempt = 1; attempt <= RPC_RETRY_ATTEMPTS; attempt += 1) {
    try {
      return await fn();
    } catch (err) {
      lastErr = err;
      if (attempt < RPC_RETRY_ATTEMPTS) {
        await sleep(RPC_RETRY_BASE_DELAY_MS * 2 ** (attempt - 1));
      }
    }
  }
  throw new Error(`${label} failed after ${RPC_RETRY_ATTEMPTS} attempts: ${errorMessage(lastErr)}`);
}

async function mapLimit<T, U>(items: T[], concurrency: number, fn: (item: T) => Promise<U>): Promise<U[]> {
  const results = new Array<U>(items.length);
  let nextIndex = 0;

  async function worker(): Promise<void> {
    while (nextIndex < items.length) {
      const index = nextIndex;
      nextIndex += 1;
      results[index] = await fn(items[index]);
    }
  }

  const workers = Array.from({ length: Math.min(concurrency, items.length) }, () => worker());
  await Promise.all(workers);
  return results;
}

function loadAbis(): {
  bridgehub: ethers.ContractInterface;
  zkChain: ethers.ContractInterface;
  l2BaseToken: ethers.ContractInterface;
} {
  return {
    bridgehub: loadAbiFromFoundryOutput("../out/IL1Bridgehub.sol/IL1Bridgehub.json"),
    zkChain: loadAbiFromFoundryOutput("../out/IZKChain.sol/IZKChain.json"),
    l2BaseToken: loadAbiFromFoundryOutput("../out/L2BaseTokenZKOS.sol/L2BaseTokenZKOS.json"),
  };
}

function openCache(cacheDir: string | null, identity: Omit<SupplyCache, "formatVersion" | "receipts">): CacheHandle {
  const empty: SupplyCache = { formatVersion: CACHE_FORMAT_VERSION, ...identity, receipts: {} };
  if (cacheDir === null) {
    return { data: empty, filePath: null };
  }

  const filePath = path.join(cacheDir, `${identity.l1ChainId}-${identity.chainId}-${identity.diamond}.json`);
  if (!fs.existsSync(filePath)) {
    return { data: empty, filePath };
  }

  const cached = JSON.parse(fs.readFileSync(filePath, "utf-8")) as SupplyCache;
  const sameIdentity =
    cached.formatVersion === CACHE_FORMAT_VERSION &&
    cached.l1ChainId === identity.l1ChainId &&
    cached.chainId === identity.chainId &&
    cached.diamond === identity.diamond;
  if (!sameIdentity) {
    console.log(`Ignoring cache file ${filePath}: it was written for another format or chain.`);
    return { data: empty, filePath };
  }
  return { data: cached, filePath };
}

function saveCache(cache: CacheHandle): void {
  if (cache.filePath === null) {
    return;
  }
  fs.mkdirSync(path.dirname(cache.filePath), { recursive: true });
  const tmpPath = `${cache.filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tmpPath, `${JSON.stringify(cache.data, null, 2)}\n`, "utf-8");
  fs.renameSync(tmpPath, cache.filePath);
}

function getScanCache<T>(
  existing: LogScanCache<T> | undefined,
  address: string,
  topics: (string | string[])[]
): LogScanCache<T> {
  if (existing && existing.address === address && JSON.stringify(existing.topics) === JSON.stringify(topics)) {
    return existing;
  }
  return { address, topics, chunks: {} };
}

/** Fails on logs the filter should not have returned: such an RPC cannot be trusted with the rest. */
function assertLogMatchesFilter(log: ethers.providers.Log, address: string, fromBlock: number, toBlock: number): void {
  if (log.removed) {
    throw new Error(`eth_getLogs returned a removed log (tx ${log.transactionHash}, block ${log.blockNumber})`);
  }
  if (log.address.toLowerCase() !== address.toLowerCase()) {
    throw new Error(`eth_getLogs for ${address} returned a log emitted by ${log.address} (tx ${log.transactionHash})`);
  }
  if (log.blockNumber < fromBlock || log.blockNumber > toBlock) {
    throw new Error(`eth_getLogs for [${fromBlock}, ${toBlock}] returned a log from block ${log.blockNumber}`);
  }
}

async function scanLogs<T>({
  provider,
  label,
  address,
  topics,
  fromBlock,
  toBlock,
  blockStep,
  toRecord,
  scanCache,
  cache,
}: {
  provider: ethers.providers.JsonRpcProvider;
  label: string;
  address: string;
  topics: (string | string[])[];
  fromBlock: number;
  toBlock: number;
  blockStep: number;
  toRecord: (log: ethers.providers.Log) => T;
  scanCache: LogScanCache<T>;
  cache: CacheHandle;
}): Promise<T[]> {
  const records: T[] = [];
  let chunks = 0;
  let cachedChunks = 0;
  let unsavedChunks = 0;

  for (let cursor = fromBlock; cursor <= toBlock; cursor += blockStep) {
    const end = Math.min(cursor + blockStep - 1, toBlock);
    const key = `${cursor}-${end}`;
    let chunk = scanCache.chunks[key];

    if (chunk) {
      cachedChunks += 1;
    } else {
      const logs = await withRetry(`${label}: eth_getLogs [${cursor}, ${end}]`, () =>
        provider.getLogs({ address, topics, fromBlock: cursor, toBlock: end })
      );
      chunk = logs.map((log) => {
        assertLogMatchesFilter(log, address, cursor, end);
        return toRecord(log);
      });
      scanCache.chunks[key] = chunk;
      unsavedChunks += 1;
      if (unsavedChunks >= CACHE_SAVE_EVERY_CHUNKS) {
        saveCache(cache);
        unsavedChunks = 0;
      }
    }

    records.push(...chunk);
    chunks += 1;
    if (chunks % PROGRESS_LOG_EVERY_CHUNKS === 0) {
      console.log(`  ${label}: scanned through block ${end}, records=${records.length}, cached chunks=${cachedChunks}`);
    }
  }

  if (unsavedChunks > 0) {
    saveCache(cache);
  }
  return records;
}

async function getRpcChainId(provider: ethers.providers.JsonRpcProvider, label: string): Promise<number> {
  const chainIdHex: string = await withRetry(`${label} eth_chainId`, () => provider.send("eth_chainId", []));
  return ethers.BigNumber.from(chainIdHex).toNumber();
}

function protocolMinorVersion(packedProtocolVersion: ethers.BigNumber): number {
  if (!packedProtocolVersion.shr(SEMVER_MAJOR_OFFSET).isZero()) {
    throw new Error(`Unsupported protocol version ${packedProtocolVersion.toString()}: the major version is not 0`);
  }
  return packedProtocolVersion.shr(SEMVER_MINOR_OFFSET).toNumber();
}

async function binarySearchFirstCodeBlock(
  provider: ethers.providers.JsonRpcProvider,
  address: string,
  lo: number,
  hi: number
): Promise<number> {
  const getCode = (blockTag: number) =>
    withRetry(`eth_getCode ${address} at block ${blockTag}`, () => provider.getCode(address, blockTag));

  if ((await getCode(hi)) === "0x") {
    throw new Error(`Address ${address} has no code at block ${hi}`);
  }
  if ((await getCode(lo)) !== "0x") {
    return lo;
  }

  while (lo < hi) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await getCode(mid)) !== "0x") {
      hi = mid;
    } else {
      lo = mid + 1;
    }
  }
  return lo;
}

/** Returns the first L1 block in [fromBlock, toBlock] at which the diamond reports protocol v0.31 or later. */
async function findV31UpgradeL1Block(zkChain: ethers.Contract, fromBlock: number, toBlock: number): Promise<number> {
  const minorAt = async (blockTag: number) =>
    protocolMinorVersion(
      await withRetry(`getProtocolVersion() at L1 block ${blockTag}`, () => zkChain.getProtocolVersion({ blockTag }))
    );

  const minorAtFrom = await minorAt(fromBlock);
  if (minorAtFrom >= V31_PROTOCOL_MINOR_VERSION) {
    throw new Error(
      `The diamond already reports protocol v0.${minorAtFrom} at L1 block ${fromBlock}: either the chain was ` +
        "created at v0.31 or later (it has no pre-v31 supply to backfill) or --from-l1-block is after its v31 upgrade"
    );
  }
  const minorAtTo = await minorAt(toBlock);
  if (minorAtTo < V31_PROTOCOL_MINOR_VERSION) {
    throw new Error(`The chain is on protocol v0.${minorAtTo} at L1 block ${toBlock}; run this after its v31 upgrade`);
  }

  // Protocol versions only grow, so the predicate is monotonic: `lo` is pre-v31 and `hi` is v31+.
  let lo = fromBlock;
  let hi = toBlock;
  while (hi - lo > 1) {
    const mid = Math.floor((lo + hi) / 2);
    if ((await minorAt(mid)) >= V31_PROTOCOL_MINOR_VERSION) {
      hi = mid;
    } else {
      lo = mid;
    }
  }
  return hi;
}

async function readL1Boundary(zkChain: ethers.Contract, upgradeL1Block: number): Promise<L1Boundary> {
  const at = { blockTag: upgradeL1Block };
  const read = <T>(getter: string): Promise<T> =>
    withRetry(`${getter}() at L1 block ${upgradeL1Block}`, () => zkChain[getter](at));

  const totalPriorityTxs = (await read<ethers.BigNumber>("getTotalPriorityTxs")).toNumber();
  const firstUnprocessedPriorityTx = (await read<ethers.BigNumber>("getFirstUnprocessedPriorityTx")).toNumber();
  const totalBatchesExecuted = (await read<ethers.BigNumber>("getTotalBatchesExecuted")).toNumber();
  const l2UpgradeTxHash = await read<string>("getL2SystemContractsUpgradeTxHash");
  const settlementLayer = await read<string>("getSettlementLayer");

  if (l2UpgradeTxHash === ethers.constants.HashZero) {
    throw new Error(
      `getL2SystemContractsUpgradeTxHash() is zero at the upgrade block ${upgradeL1Block}: the upgrade batch was ` +
        "already executed within that block (or the upgrade had no L2 tx), so the pre-upgrade " +
        "getFirstUnprocessedPriorityTx() cannot be read from state"
    );
  }
  if (settlementLayer !== ethers.constants.AddressZero) {
    throw new Error(`The chain settled on ${settlementLayer} at the v31 upgrade; only L1-settled chains are supported`);
  }
  if (firstUnprocessedPriorityTx > totalPriorityTxs) {
    throw new Error(
      `getFirstUnprocessedPriorityTx() = ${firstUnprocessedPriorityTx} > getTotalPriorityTxs() = ${totalPriorityTxs} ` +
        `at L1 block ${upgradeL1Block}`
    );
  }

  return { upgradeL1Block, totalPriorityTxs, firstUnprocessedPriorityTx, totalBatchesExecuted, l2UpgradeTxHash };
}

async function resolveL2Boundary(
  provider: ethers.providers.JsonRpcProvider,
  l2UpgradeTxHash: string
): Promise<L2Boundary> {
  const receipt = await withRetry(`L2 receipt of the upgrade tx ${l2UpgradeTxHash}`, () =>
    provider.getTransactionReceipt(l2UpgradeTxHash)
  );
  if (!receipt) {
    throw new Error(
      `--l2-rpc has no receipt for the v31 upgrade tx ${l2UpgradeTxHash} (getL2SystemContractsUpgradeTxHash() at ` +
        "the upgrade block): the L2 upgrade tx has not been executed yet, or --l2-rpc lacks this chain's history"
    );
  }
  if (receipt.status !== 1 || receipt.transactionIndex !== 0) {
    throw new Error(
      `Expected the v31 upgrade tx to succeed as tx 0 of its L2 block, got status ${receipt.status} at index ` +
        `${receipt.transactionIndex} of block ${receipt.blockNumber}`
    );
  }

  const firstV31L2Block = receipt.blockNumber;
  if (firstV31L2Block === 0) {
    throw new Error("The v31 upgrade tx is in L2 block 0: the chain has no pre-v31 blocks");
  }
  const lastPreV31L2Block = firstV31L2Block - 1;

  // The upgrade deploys L2BaseTokenZKOS at 0x...800a; before it, the base token was a system hook without code.
  const getCode = (blockTag: number) =>
    withRetry(`L2 eth_getCode at block ${blockTag}`, () => provider.getCode(L2_BASE_TOKEN_SYSTEM_CONTRACT, blockTag));
  const hasCodeBefore = (await getCode(lastPreV31L2Block)) !== "0x";
  const hasCodeAfter = (await getCode(firstV31L2Block)) !== "0x";
  if (hasCodeBefore || !hasCodeAfter) {
    throw new Error(
      `Expected ${L2_BASE_TOKEN_SYSTEM_CONTRACT} to get its code in the v31 upgrade block ${firstV31L2Block}, ` +
        `but it has code at block ${lastPreV31L2Block}: ${hasCodeBefore}, at block ${firstV31L2Block}: ${hasCodeAfter}`
    );
  }

  const cutoffBlock = await withRetry(`L2 block ${lastPreV31L2Block}`, () => provider.getBlock(lastPreV31L2Block));
  if (!cutoffBlock) {
    throw new Error(`No L2 block found for the last pre-v31 block ${lastPreV31L2Block}`);
  }

  return { firstV31L2Block, lastPreV31L2Block, cutoffTimestamp: cutoffBlock.timestamp };
}

/** Returns the requests indexed by txId, or throws unless the txIds are exactly 0..N-1. */
function assertCompletePriorityRequests(
  records: PriorityRequestRecord[],
  totalPriorityTxs: number,
  scannedRange: string
): PriorityRequestRecord[] {
  const byTxId = new Array<PriorityRequestRecord | undefined>(totalPriorityTxs);
  const duplicated: number[] = [];
  const outOfRange: number[] = [];
  for (const record of records) {
    if (record.txId >= totalPriorityTxs) {
      outOfRange.push(record.txId);
    } else if (byTxId[record.txId]) {
      duplicated.push(record.txId);
    } else {
      byTxId[record.txId] = record;
    }
  }

  const missing: number[] = [];
  for (let txId = 0; txId < totalPriorityTxs; txId += 1) {
    if (!byTxId[txId]) {
      missing.push(txId);
    }
  }

  if (missing.length > 0 || duplicated.length > 0 || outOfRange.length > 0) {
    const issues = [
      ...missing.map((txId) => `txId ${txId}: missing`),
      ...duplicated.map((txId) => `txId ${txId}: duplicated`),
      ...outOfRange.map((txId) => `txId ${txId}: not below getTotalPriorityTxs()`),
    ];
    throw new Error(
      `Incomplete L1 data: getTotalPriorityTxs() is ${totalPriorityTxs} at the upgrade block, but the ` +
        `NewPriorityRequest logs in ${scannedRange} hold ${records.length} entries ` +
        `(${missing.length} missing, ${duplicated.length} duplicated, ${outOfRange.length} out of range):\n` +
        `${formatIssues(issues)}\n` +
        "Some RPCs silently return no logs for old ranges. Rerun with another --l1-rpc; the cached L1 logs were dropped."
    );
  }
  return byTxId as PriorityRequestRecord[];
}

async function fetchReceipts({
  provider,
  requests,
  concurrency,
  cache,
}: {
  provider: ethers.providers.JsonRpcProvider;
  requests: PriorityRequestRecord[];
  concurrency: number;
  cache: CacheHandle;
}): Promise<(ReceiptRecord | null)[]> {
  let fetched = 0;
  const receipts = await mapLimit(requests, concurrency, async (request) => {
    const cached = cache.data.receipts[request.txHash];
    if (cached) {
      return cached;
    }

    const receipt = await withRetry(`L2 receipt of priority tx ${request.txId}`, () =>
      provider.getTransactionReceipt(request.txHash)
    );
    fetched += 1;
    if (fetched % PROGRESS_LOG_EVERY_RECEIPTS === 0) {
      console.log(`  L2 receipts: fetched ${fetched}`);
      saveCache(cache);
    }
    if (!receipt) {
      return null;
    }
    if (receipt.status === undefined) {
      throw new Error(`L2 receipt of priority tx ${request.txId} (${request.txHash}) has no status`);
    }

    const record: ReceiptRecord = {
      blockNumber: receipt.blockNumber,
      transactionIndex: receipt.transactionIndex,
      status: receipt.status,
    };
    cache.data.receipts[request.txHash] = record;
    return record;
  });

  saveCache(cache);
  return receipts;
}

/**
 * The deposit sum is defined by txId < k alone; the receipts only cross-check it. Every txId < k must
 * have been executed in a pre-v31 L2 block, in txId order, and no txId >= k may have been.
 */
function crossCheckReceipts({
  requests,
  receipts,
  firstUnprocessedPriorityTx,
  lastPreV31L2Block,
}: {
  requests: PriorityRequestRecord[];
  receipts: (ReceiptRecord | null)[];
  firstUnprocessedPriorityTx: number;
  lastPreV31L2Block: number;
}): ReceiptStats {
  const stats: ReceiptStats = {
    succeededBeforeBoundary: 0,
    revertedBeforeBoundary: 0,
    executedAfterBoundary: 0,
    notExecutedYet: 0,
  };
  const issues: string[] = [];
  let previous: { txId: number; receipt: ReceiptRecord } | null = null;

  for (let index = 0; index < requests.length; index += 1) {
    const request = requests[index];
    const receipt = receipts[index];
    const label = `txId ${request.txId} (${request.txHash})`;

    if (request.txId >= firstUnprocessedPriorityTx) {
      if (!receipt) {
        stats.notExecutedYet += 1;
      } else if (receipt.blockNumber <= lastPreV31L2Block) {
        issues.push(
          `${label}: not executed on L1 by the upgrade, yet its L2 receipt is in pre-v31 block ${receipt.blockNumber}`
        );
      } else {
        stats.executedAfterBoundary += 1;
      }
      continue;
    }

    if (!receipt) {
      issues.push(`${label}: executed on L1 by the upgrade, yet --l2-rpc has no receipt for it`);
      continue;
    }
    if (receipt.blockNumber > lastPreV31L2Block) {
      issues.push(`${label}: executed on L1 by the upgrade, yet its L2 receipt is in v31 block ${receipt.blockNumber}`);
      continue;
    }
    if (
      previous &&
      (receipt.blockNumber < previous.receipt.blockNumber ||
        (receipt.blockNumber === previous.receipt.blockNumber &&
          receipt.transactionIndex <= previous.receipt.transactionIndex))
    ) {
      issues.push(
        `${label}: L2 position (block ${receipt.blockNumber}, index ${receipt.transactionIndex}) is not after ` +
          `txId ${previous.txId}'s (block ${previous.receipt.blockNumber}, index ${previous.receipt.transactionIndex})`
      );
    }
    previous = { txId: request.txId, receipt };

    if (receipt.status === 1) {
      stats.succeededBeforeBoundary += 1;
    } else {
      stats.revertedBeforeBoundary += 1;
    }
  }

  if (issues.length > 0) {
    throw new Error(
      `L2 receipts contradict the L1 boundary (k = ${firstUnprocessedPriorityTx}, last pre-v31 L2 block ` +
        `${lastPreV31L2Block}), ${issues.length} issue(s):\n${formatIssues(issues)}\n` +
        "Point --l2-rpc at this chain's own node with full history."
    );
  }
  return stats;
}

function parseOptions(): Options {
  const program = new Command();

  program
    .name("calculate-zkos-pre-v31-total-supply")
    .description("Calculate the value for AdminFacet.setZKsyncOSPreV31TotalSupply(). See the script header.")
    .requiredOption("--chain-id <n>", "ZK chain id", parsePositiveInt)
    .requiredOption("--bridgehub <address>", "L1 Bridgehub address")
    .requiredOption("--l1-rpc <url>", "L1 RPC URL; must serve historical state (archive node)")
    .requiredOption("--l2-rpc <url>", "RPC URL of the chain's own node, with full history")
    .option(
      "--upgrade-l1-tx <hash>",
      "The chain's v31 upgrade tx on L1. Optional cross-check: the upgrade block is derived from the protocol version"
    )
    .option(
      "--from-l1-block <n>",
      "First L1 block of the NewPriorityRequest scan; defaults to the diamond's deployment block",
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
    )
    .option("--cache-dir <dir>", "Directory for cached logs and receipts", DEFAULT_CACHE_DIR)
    .option("--no-cache", "Do not read or write the cache");

  return program.parse(process.argv).opts<Options>();
}

async function calculate(opts: Options): Promise<void> {
  if (LEGACY_ZKSYNC_OS_CHAIN_IDS.has(opts.chainId)) {
    throw new Error(
      `Chain ${opts.chainId} has zksync-os v0.0.x history. Those blocks burned withdrawn base token without ` +
        "emitting Withdrawal events, so this calculator would overstate its supply"
    );
  }

  const abis = loadAbis();
  const l1Provider = new ethers.providers.StaticJsonRpcProvider(opts.l1Rpc);
  const l2Provider = new ethers.providers.StaticJsonRpcProvider(opts.l2Rpc);
  const bridgehubAddress = ethers.utils.getAddress(opts.bridgehub);
  const bridgehub = new ethers.Contract(bridgehubAddress, abis.bridgehub, l1Provider);
  const l2BaseToken = new ethers.Contract(L2_BASE_TOKEN_SYSTEM_CONTRACT, abis.l2BaseToken, l2Provider);

  const l2RpcChainId = await getRpcChainId(l2Provider, "L2");
  if (l2RpcChainId !== opts.chainId) {
    throw new Error(`--l2-rpc serves chain ${l2RpcChainId}, not --chain-id ${opts.chainId}`);
  }

  // Pin "latest" so every read below sees the same L1 state.
  const latestL1Block = await withRetry("L1 eth_blockNumber", () => l1Provider.getBlockNumber());
  const atLatest = { blockTag: latestL1Block };
  const l1ChainId = await getRpcChainId(l1Provider, "L1");
  const bridgehubCode = await withRetry("Bridgehub eth_getCode", () =>
    l1Provider.getCode(bridgehubAddress, latestL1Block)
  );
  if (bridgehubCode === "0x") {
    throw new Error(`--bridgehub ${bridgehubAddress} has no code on chain ${l1ChainId} served by --l1-rpc`);
  }
  // L1Bridgehub sets L1_CHAIN_ID to block.chainid in its constructor.
  const bridgehubL1ChainId = (
    await withRetry<ethers.BigNumber>("Bridgehub L1_CHAIN_ID()", () => bridgehub.L1_CHAIN_ID(atLatest))
  ).toNumber();
  if (l1ChainId !== bridgehubL1ChainId) {
    throw new Error(
      `--l1-rpc serves chain ${l1ChainId}, but the bridgehub was deployed on chain ${bridgehubL1ChainId}`
    );
  }

  const diamond = ethers.utils.getAddress(
    await withRetry("Bridgehub getZKChain()", () => bridgehub.getZKChain(opts.chainId, atLatest))
  );
  if (diamond === ethers.constants.AddressZero) {
    throw new Error(`Bridgehub ${bridgehubAddress} returned zero address for chain ${opts.chainId}`);
  }
  const zkChain = new ethers.Contract(diamond, abis.zkChain, l1Provider);
  const diamondChainId = (
    await withRetry<ethers.BigNumber>("getChainId()", () => zkChain.getChainId(atLatest))
  ).toNumber();
  if (diamondChainId !== opts.chainId) {
    throw new Error(`Diamond ${diamond} reports chain id ${diamondChainId}, not ${opts.chainId}`);
  }

  // getZKsyncOS() only exists from v31 on, so check the version first.
  const latestMinor = protocolMinorVersion(
    await withRetry("getProtocolVersion()", () => zkChain.getProtocolVersion(atLatest))
  );
  if (latestMinor < V31_PROTOCOL_MINOR_VERSION) {
    throw new Error(`Chain ${opts.chainId} is on protocol v0.${latestMinor}; run this after its v31 upgrade`);
  }
  if (!(await withRetry("getZKsyncOS()", () => zkChain.getZKsyncOS(atLatest)))) {
    throw new Error(`Chain ${opts.chainId} is not a ZKsync OS chain; Era chains track their base-token supply`);
  }

  let fromL1Block: number;
  if (opts.fromL1Block === undefined) {
    fromL1Block = await binarySearchFirstCodeBlock(l1Provider, diamond, 0, latestL1Block);
  } else {
    fromL1Block = opts.fromL1Block;
    const code = await withRetry("eth_getCode", () => l1Provider.getCode(diamond, fromL1Block));
    if (code === "0x") {
      throw new Error(`Diamond ${diamond} has no code at --from-l1-block ${fromL1Block}`);
    }
  }

  const upgradeL1Block = await findV31UpgradeL1Block(zkChain, fromL1Block, latestL1Block);
  if (opts.upgradeL1Tx) {
    const receipt = await withRetry("L1 receipt of --upgrade-l1-tx", () =>
      l1Provider.getTransactionReceipt(opts.upgradeL1Tx as string)
    );
    if (!receipt || receipt.status !== 1 || receipt.blockNumber !== upgradeL1Block) {
      throw new Error(
        `--upgrade-l1-tx ${opts.upgradeL1Tx} is not a successful tx in the derived v31 upgrade block ${upgradeL1Block} ` +
          `(receipt: ${receipt ? `block ${receipt.blockNumber}, status ${receipt.status}` : "none"})`
      );
    }
  }

  const l1Boundary = await readL1Boundary(zkChain, upgradeL1Block);
  const l2Boundary = await resolveL2Boundary(l2Provider, l1Boundary.l2UpgradeTxHash);
  const cache = openCache(opts.cache ? opts.cacheDir : null, { l1ChainId, chainId: opts.chainId, diamond });

  console.log("Calculation plan:");
  console.log(`  L1 chain id:              ${l1ChainId}`);
  console.log(`  chain id:                 ${opts.chainId}`);
  console.log(`  bridgehub:                ${bridgehubAddress}`);
  console.log(`  diamond proxy:            ${diamond}`);
  console.log(`  v31 upgrade L1 block:     ${upgradeL1Block}`);
  console.log(`  L1 scan range:            [${fromL1Block}, ${upgradeL1Block}]`);
  console.log(
    `  priority txs at upgrade:  ${l1Boundary.totalPriorityTxs} (executed: ${l1Boundary.firstUnprocessedPriorityTx})`
  );
  console.log(`  batches executed:         ${l1Boundary.totalBatchesExecuted}`);
  console.log(
    `  L2 upgrade tx:            ${l1Boundary.l2UpgradeTxHash} (tx 0 of L2 block ${l2Boundary.firstV31L2Block})`
  );
  console.log(`  L2 pre-v31 range:         [0, ${l2Boundary.lastPreV31L2Block}]`);
  console.log(
    `  cutoff date:              ${formatUtcDate(l2Boundary.cutoffTimestamp)} (L2 block ${l2Boundary.lastPreV31L2Block})`
  );
  console.log(`  getLogs block step:       ${opts.blockStep}`);
  console.log(`  receipt concurrency:      ${opts.receiptConcurrency}`);
  console.log(`  cache file:               ${cache.filePath ?? "disabled"}`);

  console.log("\n[1/3] Reading L1 priority requests...");
  const newPriorityRequestTopic = zkChain.interface.getEventTopic("NewPriorityRequest");
  const priorityRequestScan = getScanCache(cache.data.priorityRequests, diamond, [newPriorityRequestTopic]);
  cache.data.priorityRequests = priorityRequestScan;
  const priorityRequestRecords = await scanLogs<PriorityRequestRecord>({
    provider: l1Provider,
    label: "L1 NewPriorityRequest",
    address: diamond,
    topics: [newPriorityRequestTopic],
    fromBlock: fromL1Block,
    toBlock: upgradeL1Block,
    blockStep: opts.blockStep,
    toRecord: (log) => {
      const parsed = zkChain.interface.parseLog(log);
      if (parsed.name !== "NewPriorityRequest") {
        throw new Error(`eth_getLogs returned a ${parsed.name} log for the NewPriorityRequest filter`);
      }
      const txId = parsed.args.txId as ethers.BigNumber;
      if (!parsed.args.transaction.nonce.eq(txId)) {
        throw new Error(`NewPriorityRequest in L1 tx ${log.transactionHash}: transaction.nonce != txId ${txId}`);
      }
      return {
        txId: txId.toNumber(),
        txHash: parsed.args.txHash,
        mintValue: parsed.args.transaction.reserved[0].toString(),
        l1BlockNumber: log.blockNumber,
      };
    },
    scanCache: priorityRequestScan,
    cache,
  });

  let requests: PriorityRequestRecord[];
  try {
    requests = assertCompletePriorityRequests(
      priorityRequestRecords,
      l1Boundary.totalPriorityTxs,
      `[${fromL1Block}, ${upgradeL1Block}]`
    );
  } catch (err) {
    delete cache.data.priorityRequests;
    saveCache(cache);
    throw err;
  }

  const k = l1Boundary.firstUnprocessedPriorityTx;
  let deposits = ethers.constants.Zero;
  let zeroMintValue = 0;
  for (const request of requests.slice(0, k)) {
    const mintValue = ethers.BigNumber.from(request.mintValue);
    deposits = deposits.add(mintValue);
    if (mintValue.isZero()) {
      zeroMintValue += 1;
    }
  }
  const txIdRange = requests.length === 0 ? "none" : `txIds 0..${requests.length - 1}`;
  console.log(`  NewPriorityRequest logs:  ${requests.length} (${txIdRange}, complete)`);
  console.log(`  executed before v31:      ${k} (txId < ${k}), ${zeroMintValue} of them with zero mintValue`);
  console.log(`  totalExecutedDeposits:    ${formatAmount(deposits)}`);

  console.log("\n[2/3] Cross-checking L2 priority transaction receipts...");
  const receipts = await fetchReceipts({
    provider: l2Provider,
    requests,
    concurrency: opts.receiptConcurrency,
    cache,
  });
  const receiptStats = crossCheckReceipts({
    requests,
    receipts,
    firstUnprocessedPriorityTx: k,
    lastPreV31L2Block: l2Boundary.lastPreV31L2Block,
  });
  console.log(`  succeeded before v31:     ${receiptStats.succeededBeforeBoundary}`);
  console.log(`  reverted before v31:      ${receiptStats.revertedBeforeBoundary} (counted: mintValue was minted)`);
  console.log(`  executed after v31:       ${receiptStats.executedAfterBoundary} (not counted)`);
  console.log(`  not executed yet:         ${receiptStats.notExecutedYet} (not counted)`);

  console.log("\n[3/3] Summing L2 withdrawals...");
  const withdrawalTopics = [
    [l2BaseToken.interface.getEventTopic("Withdrawal"), l2BaseToken.interface.getEventTopic("WithdrawalWithMessage")],
  ];
  const withdrawalScan = getScanCache(cache.data.withdrawals, L2_BASE_TOKEN_SYSTEM_CONTRACT, withdrawalTopics);
  cache.data.withdrawals = withdrawalScan;
  const withdrawalRecords = await scanLogs<WithdrawalRecord>({
    provider: l2Provider,
    label: "L2 withdrawals",
    address: L2_BASE_TOKEN_SYSTEM_CONTRACT,
    topics: withdrawalTopics,
    fromBlock: 0,
    toBlock: l2Boundary.lastPreV31L2Block,
    blockStep: opts.blockStep,
    toRecord: (log) => {
      const parsed = l2BaseToken.interface.parseLog(log);
      if (parsed.name !== "Withdrawal" && parsed.name !== "WithdrawalWithMessage") {
        throw new Error(`eth_getLogs returned a ${parsed.name} log for the withdrawal filter`);
      }
      return { l2BlockNumber: log.blockNumber, event: parsed.name, amount: parsed.args._amount.toString() };
    },
    scanCache: withdrawalScan,
    cache,
  });

  let withdrawals = ethers.constants.Zero;
  for (const record of withdrawalRecords) {
    withdrawals = withdrawals.add(record.amount);
  }
  const countEvents = (name: string) => withdrawalRecords.filter((record) => record.event === name).length;
  console.log(`  Withdrawal logs:          ${countEvents("Withdrawal")}`);
  console.log(`  WithdrawalWithMessage:    ${countEvents("WithdrawalWithMessage")}`);
  console.log(`  totalWithdrawalsToL1:     ${formatAmount(withdrawals)}`);

  if (deposits.lt(withdrawals)) {
    throw new Error(
      `Computed deposits < withdrawals: deposits=${deposits.toString()} withdrawals=${withdrawals.toString()}`
    );
  }

  const preV31TotalSupply = deposits.sub(withdrawals);
  console.log("\nResult:");
  console.log(
    `  cutoff date:              ${formatUtcDate(l2Boundary.cutoffTimestamp)} (L2 block ${l2Boundary.lastPreV31L2Block})`
  );
  console.log(`  total deposited:          ${formatAmount(deposits)}`);
  console.log(`  total withdrawn:          ${formatAmount(withdrawals)}`);
  console.log(`  preV31TotalSupply:        ${formatAmount(preV31TotalSupply)}`);
  console.log(`  raw uint256:              ${preV31TotalSupply.toString()}`);

  if (!(await withRetry("baseTokenSupportsTotalSupply()", () => zkChain.baseTokenSupportsTotalSupply(atLatest)))) {
    console.log("  on-chain value:           not set yet");
    return;
  }
  const onChainValue: ethers.BigNumber = await withRetry("L2 zkosPreV31TotalSupply()", () =>
    l2BaseToken.zkosPreV31TotalSupply()
  );
  if (onChainValue.isZero()) {
    console.log("  on-chain value:           set on L1, the service tx has not been executed on L2 yet");
    return;
  }
  console.log(`  on-chain value:           ${formatAmount(onChainValue)}`);
  if (!onChainValue.eq(preV31TotalSupply)) {
    throw new Error(
      `The value already set on-chain differs from the computed one by ${formatAmount(onChainValue.sub(preV31TotalSupply))}`
    );
  }
  console.log("  matches the computed value");
}

async function main(): Promise<void> {
  const opts = parseOptions();
  try {
    await calculate(opts);
  } catch (err) {
    const message = err instanceof Error ? (err.stack ?? err.message) : String(err);
    console.error(redactRpcUrls(message, [opts.l1Rpc, opts.l2Rpc]));
    process.exit(1);
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? (err.stack ?? err.message) : err);
  process.exit(1);
});

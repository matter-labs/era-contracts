#!/usr/bin/env ts-node
/**
 * Script to collect and persist historical migration intervals for chains that
 * settled on the legacy ZK Gateway, and to write those intervals into the
 * permanent-values TOML file so that v31's `setHistoricalMigrationInterval`
 * can be called with the correct data.
 *
 * Commands:
 *
 *   collect --rpc <url> --env <name>
 *     Connects to the given L1 RPC, reads the bridgehub address from the
 *     permanent-values TOML for <env>, and scans all MigrationStarted /
 *     MigrationFinalized events emitted by the L1ChainAssetHandler.
 *     Note: events are matched against the legacy on-chain interface (main branch)
 *     which does NOT include migrationNumber.
 *
 *     For each chain, historical state calls via the chain's diamond-proxy Getters
 *     facet derive the four batch-number fields required by `MigrationInterval`:
 *       - migrateToGWBatchNumber   (chain's L1 batch at migration-to block)
 *       - slBatchLowerBound        (legacy GW's batch at migration-to block)
 *       - migrateFromGWBatchNumber (chain's batch at migration-from block)
 *       - slBatchUpperBound        (legacy GW's batch at migration-from block)
 *
 *     The scan starts from the block where the legacy GW's diamond proxy was first
 *     deployed (found via binary search) to avoid scanning all of L1 history.
 *     This block is persisted to the JSON cache alongside the interval data.
 *
 *     Results are cached in:
 *       script-out/<env>-gateway-migration-intervals.json
 *
 *   write --env <name>
 *     Reads the cached JSON file and writes [[legacy_gateway.chain_intervals]]
 *     entries into upgrade-envs/permanent-values/<env>.toml, replacing the
 *     existing TODO(EVM-1221) placeholder comment block.
 *
 * Prerequisites for `collect`:
 *   Run `forge build` in l1-contracts/ to generate ABI files in out/.
 */

import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { Command } from "commander";
import {
  PERMANENT_VALUES_DIR,
  SCRIPT_OUT_DIR,
  getBridgehubAddress,
  getLegacyGatewayChainId,
} from "./upgrade-script-utils";

// ─── Constants ────────────────────────────────────────────────────────────────

const BLOCK_STEP = 10_000;

const CACHE_FILE_SUFFIX = "gateway-migration-intervals.json";

// ─── Legacy on-chain event interface ─────────────────────────────────────────
// The deployed ChainAssetHandler was compiled from the main branch, which does
// NOT include the migrationNumber parameter added in draft-v31.  We must use
// this exact signature so that ethers.js produces the correct topic hash.

const LEGACY_CHAIN_ASSET_HANDLER_ABI = [
  "event MigrationStarted(uint256 indexed chainId, bytes32 indexed assetId, uint256 indexed settlementLayerChainId)",
  "event MigrationFinalized(uint256 indexed chainId, bytes32 indexed assetId, address indexed zkChain)",
];

// ─── Data types ───────────────────────────────────────────────────────────────

/** Full batch-counter snapshot for one chain at one block. */
interface BatchSnapshot {
  blockNumber: number;
  totalBatchesExecuted: number;
  totalBatchesVerified: number;
  totalBatchesCommitted: number;
}

/**
 * One completed migration interval for a chain.
 * A single chain may have multiple intervals if it migrated to/from the legacy GW
 * more than once.
 */
interface ChainMigrationInterval {
  chainId: number;
  /** Last L1 batch of the chain before it migrated TO the legacy GW. */
  migrateToGWBatchNumber: number;
  /** Last legacy-GW batch of the chain when it migrated FROM the legacy GW back to L1. */
  migrateFromGWBatchNumber: number;
  /** Legacy-GW's own batch number at the time the chain migrated TO it (lower bound). */
  slBatchLowerBound: number;
  /** Legacy-GW's own batch number at the time the chain migrated FROM it (upper bound). */
  slBatchUpperBound: number;
  /** Full batch snapshots used to derive the interval (for auditing). */
  snapshots: {
    chainAtMigrationStarted: BatchSnapshot;
    gwAtMigrationStarted: BatchSnapshot;
    chainAtMigrationFinalized: BatchSnapshot;
    gwAtMigrationFinalized: BatchSnapshot;
  };
}

/** JSON cache format stored in script-out/. */
interface CollectedData {
  /** First block scanned (block at which the legacy GW diamond proxy was deployed). */
  firstBlock: number;
  /** Last block scanned (inclusive). */
  lastBlock: number;
  /** Completed migration intervals, one per chain. */
  intervals: ChainMigrationInterval[];
}

// ─── Helpers ─────────────────────────────────────────────────────────────────

function cacheFilePath(envName: string): string {
  return path.join(SCRIPT_OUT_DIR, `${envName}-${CACHE_FILE_SUFFIX}`);
}

/**
 * Binary-searches the block range [lo, hi] for the first block at which
 * `address` has non-empty code (i.e. has been deployed).
 */
async function binarySearchDeployBlock(
  provider: ethers.providers.JsonRpcProvider,
  address: string,
  lo: number,
  hi: number
): Promise<number> {
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

/** Reads all three batch counters from a ZK-chain diamond proxy at a given block. */
async function getBatchSnapshot(
  diamondProxy: ethers.Contract,
  blockNumber: number
): Promise<BatchSnapshot> {
  const [executed, verified, committed] = await Promise.all([
    diamondProxy.callStatic.getTotalBatchesExecuted({ blockTag: blockNumber }) as Promise<ethers.BigNumber>,
    diamondProxy.callStatic.getTotalBatchesVerified({ blockTag: blockNumber }) as Promise<ethers.BigNumber>,
    diamondProxy.callStatic.getTotalBatchesCommitted({ blockTag: blockNumber }) as Promise<ethers.BigNumber>,
  ]);
  return {
    blockNumber,
    totalBatchesExecuted: executed.toNumber(),
    totalBatchesVerified: verified.toNumber(),
    totalBatchesCommitted: committed.toNumber(),
  };
}

// ─── collect command ──────────────────────────────────────────────────────────

async function collect(rpc: string, envName: string): Promise<void> {
  const bridgehubAddress = getBridgehubAddress(envName);
  const legacyGwChainId = getLegacyGatewayChainId(envName);

  if (legacyGwChainId === 0) {
    throw new Error(
      `legacy_gateway.chain_id not configured in ${envName}.toml — nothing to collect`
    );
  }

  console.log(`Bridgehub:       ${bridgehubAddress}`);
  console.log(`Legacy GW chain: ${legacyGwChainId}`);

  const provider = new ethers.providers.JsonRpcProvider(rpc);

  // Load ABIs from forge build output (requires `forge build` in l1-contracts/).
  const bridgehubAbi = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../out/IBridgehubBase.sol/IBridgehubBase.json"), "utf-8")
  ).abi;
  const zkChainAbi = JSON.parse(
    fs.readFileSync(path.join(__dirname, "../out/IZKChain.sol/IZKChain.json"), "utf-8")
  ).abi;

  const bridgehub = new ethers.Contract(bridgehubAddress, bridgehubAbi, provider);

  const chainAssetHandlerAddress: string = await bridgehub.chainAssetHandler();
  console.log(`ChainAssetHandler: ${chainAssetHandlerAddress}`);

  // Migration events are emitted by BOTH the Bridgehub (legacy architecture) and the
  // ChainAssetHandler (new architecture). Query both and deduplicate by txHash+logIndex.
  const bridgehubContract = new ethers.Contract(bridgehubAddress, LEGACY_CHAIN_ASSET_HANDLER_ABI, provider);
  const cahContract = new ethers.Contract(chainAssetHandlerAddress, LEGACY_CHAIN_ASSET_HANDLER_ABI, provider);

  // ── Determine scan start block ────────────────────────────────────────────

  const legacyGwDiamondProxy: string = await bridgehub.getZKChain(legacyGwChainId);
  console.log(`Legacy GW proxy: ${legacyGwDiamondProxy}`);

  const latestBlock = await provider.getBlockNumber();

  console.log("\nBinary-searching for legacy GW deployment block…");
  const firstBlock = await binarySearchDeployBlock(provider, legacyGwDiamondProxy, 0, latestBlock);
  console.log(`Legacy GW deployed at block: ${firstBlock}`);
  console.log(`Scanning ${firstBlock} – ${latestBlock} in ${BLOCK_STEP}-block chunks…\n`);

  // ── Single scan loop ──────────────────────────────────────────────────────

  const startedFilterBH = bridgehubContract.filters.MigrationStarted();
  const finalizedFilterBH = bridgehubContract.filters.MigrationFinalized();
  const startedFilterCAH = cahContract.filters.MigrationStarted();
  const finalizedFilterCAH = cahContract.filters.MigrationFinalized();

  const seenKeys = new Set<string>();
  const allStarted: ethers.Event[] = [];
  const allFinalized: ethers.Event[] = [];

  function dedup(ev: ethers.Event): boolean {
    const key = `${ev.transactionHash}:${ev.logIndex}`;
    if (seenKeys.has(key)) return false;
    seenKeys.add(key);
    return true;
  }

  for (let from = firstBlock; from <= latestBlock; from += BLOCK_STEP) {
    const to = Math.min(from + BLOCK_STEP - 1, latestBlock);

    const [bhStarted, bhFinalized, cahStarted, cahFinalized] = await Promise.all([
      bridgehubContract.queryFilter(startedFilterBH, from, to),
      bridgehubContract.queryFilter(finalizedFilterBH, from, to),
      cahContract.queryFilter(startedFilterCAH, from, to),
      cahContract.queryFilter(finalizedFilterCAH, from, to),
    ]);

    for (const ev of [...bhStarted, ...cahStarted]) if (dedup(ev)) allStarted.push(ev);
    for (const ev of [...bhFinalized, ...cahFinalized]) if (dedup(ev)) allFinalized.push(ev);

    console.log(
      `  blocks ${from}–${to}:` +
        ` +${bhStarted.length + cahStarted.length} MigrationStarted (BH:${bhStarted.length}/CAH:${cahStarted.length}),` +
        ` +${bhFinalized.length + cahFinalized.length} MigrationFinalized (BH:${bhFinalized.length}/CAH:${cahFinalized.length})`
    );
  }

  console.log(
    `\nTotal: ${allStarted.length} MigrationStarted, ${allFinalized.length} MigrationFinalized`
  );

  // Sort both lists chronologically for the state-machine pairing below.
  allStarted.sort((a, b) => a.blockNumber - b.blockNumber);
  allFinalized.sort((a, b) => a.blockNumber - b.blockNumber);

  // ── Pre-fetch diamond proxy contracts ─────────────────────────────────────

  const gwProxy = new ethers.Contract(legacyGwDiamondProxy, zkChainAbi, provider);

  const chainProxies = new Map<number, ethers.Contract>();
  for (const ev of allStarted) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    if (!chainProxies.has(chainId)) {
      const proxyAddr: string = await bridgehub.getZKChain(chainId);
      chainProxies.set(chainId, new ethers.Contract(proxyAddr, zkChainAbi, provider));
      console.log(`  chain ${chainId} diamond proxy: ${proxyAddr}`);
    }
  }

  // ── Derive intervals via per-chain state machine ──────────────────────────
  // Process MigrationStarted events chronologically. For each one targeting the
  // legacy GW, find the next MigrationFinalized for that chain (by block number).
  // A chain may have migrated multiple times — each Start/End pair is one interval.

  const intervals: ChainMigrationInterval[] = [];

  // Per-chain consumption index into allFinalized (sorted).
  const finalizedQueues = new Map<number, ethers.Event[]>();
  for (const ev of allFinalized) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    if (!finalizedQueues.has(chainId)) finalizedQueues.set(chainId, []);
    finalizedQueues.get(chainId)!.push(ev);
  }
  const finalizedIdx = new Map<number, number>();

  // Track chains that started but haven't finalized yet (for the ❌ report).
  const openMigrations = new Map<number, number>(); // chainId → startedBlock

  for (const ev of allStarted) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    const slChainId = (ev.args!.settlementLayerChainId as ethers.BigNumber).toNumber();
    if (slChainId !== legacyGwChainId) continue;

    const startedBlock = ev.blockNumber;
    openMigrations.set(chainId, startedBlock);

    // Find the next MigrationFinalized for this chain after startedBlock.
    const queue = finalizedQueues.get(chainId) ?? [];
    const idx = finalizedIdx.get(chainId) ?? 0;
    const matchPos = queue.findIndex((f, i) => i >= idx && f.blockNumber > startedBlock);

    if (matchPos === -1) {
      // No return yet — will be reported after the loop.
      continue;
    }
    finalizedIdx.set(chainId, matchPos + 1);
    openMigrations.delete(chainId);

    const finalizedBlock = queue[matchPos].blockNumber;
    const chainProxy = chainProxies.get(chainId)!;

    console.log(
      `\n  chain ${chainId}: MigrationStarted block=${startedBlock}, MigrationFinalized block=${finalizedBlock}`
    );

    const [chainAtStart, gwAtStart, chainAtEnd, gwAtEnd] = await Promise.all([
      getBatchSnapshot(chainProxy, startedBlock),
      getBatchSnapshot(gwProxy, startedBlock),
      getBatchSnapshot(chainProxy, finalizedBlock),
      getBatchSnapshot(gwProxy, finalizedBlock),
    ]);

    console.log(
      `    migrateToGW=${chainAtStart.totalBatchesExecuted}` +
        ` slLower=${gwAtStart.totalBatchesExecuted}` +
        ` migrateFromGW=${chainAtEnd.totalBatchesExecuted}` +
        ` slUpper=${gwAtEnd.totalBatchesExecuted}`
    );

    intervals.push({
      chainId,
      migrateToGWBatchNumber: chainAtStart.totalBatchesExecuted,
      migrateFromGWBatchNumber: chainAtEnd.totalBatchesExecuted,
      slBatchLowerBound: gwAtStart.totalBatchesExecuted,
      slBatchUpperBound: gwAtEnd.totalBatchesExecuted,
      snapshots: {
        chainAtMigrationStarted: chainAtStart,
        gwAtMigrationStarted: gwAtStart,
        chainAtMigrationFinalized: chainAtEnd,
        gwAtMigrationFinalized: gwAtEnd,
      },
    });
  }

  // Report any chains still on the legacy GW.
  for (const [chainId, startBlock] of openMigrations) {
    console.log(
      `❌  chain ${chainId} (MigrationStarted at block ${startBlock}) has NOT returned from the legacy GW`
    );
  }

  // ── Persist cache ─────────────────────────────────────────────────────────

  const output: CollectedData = { firstBlock, lastBlock: latestBlock, intervals };

  if (!fs.existsSync(SCRIPT_OUT_DIR)) {
    fs.mkdirSync(SCRIPT_OUT_DIR, { recursive: true });
  }

  const outFile = cacheFilePath(envName);
  fs.writeFileSync(outFile, JSON.stringify(output, null, 2));

  console.log(`\nFound ${intervals.length} completed interval(s).`);
  console.log(`Saved to: ${outFile}`);
}

// ─── write command ────────────────────────────────────────────────────────────

function write(envName: string): void {
  const cacheFile = cacheFilePath(envName);

  if (!fs.existsSync(cacheFile)) {
    throw new Error(
      `Cache file not found: ${cacheFile}\n` +
        `Run: yarn collect-gateway-migration-intervals collect --rpc <RPC_URL> --env ${envName}`
    );
  }

  const data: CollectedData = JSON.parse(fs.readFileSync(cacheFile, "utf-8"));

  if (data.intervals.length === 0) {
    console.log(`No completed intervals found in ${cacheFile} — nothing to write.`);
    return;
  }

  const permanentValuesFile = path.join(PERMANENT_VALUES_DIR, `${envName}.toml`);

  if (!fs.existsSync(permanentValuesFile)) {
    throw new Error(`Permanent values file not found: ${permanentValuesFile}`);
  }

  const raw = fs.readFileSync(permanentValuesFile, "utf-8");

  // `legacy_gateway.chain_intervals` is always the last section in the file.
  // Truncate at the first line that begins that section — whether it is a real
  // entry or a commented-out placeholder — then re-append the derived values.
  // This makes the command idempotent.
  const lines = raw.split("\n");
  const cutoff = lines.findIndex(
    (l) => l.startsWith("[[legacy_gateway.chain_intervals]]") || l.startsWith("# [[legacy_gateway.chain_intervals]]")
  );
  const base = (cutoff === -1 ? raw : lines.slice(0, cutoff).join("\n")).trimEnd();
  const content = base + "\n\n" + data.intervals.map(serializeInterval).join("\n") + "\n";

  fs.writeFileSync(permanentValuesFile, content);

  console.log(`Wrote ${data.intervals.length} interval(s) to ${permanentValuesFile}`);
  for (const interval of data.intervals) {
    console.log(
      `  chain ${interval.chainId}: ` +
        `migrateToGW=${interval.migrateToGWBatchNumber} ` +
        `migrateFromGW=${interval.migrateFromGWBatchNumber} ` +
        `slLower=${interval.slBatchLowerBound} ` +
        `slUpper=${interval.slBatchUpperBound}`
    );
  }
}

// ─── TOML serialisation ───────────────────────────────────────────────────────

function serializeInterval(interval: ChainMigrationInterval): string {
  return (
    `[[legacy_gateway.chain_intervals]]\n` +
    `chain_id = ${interval.chainId}\n` +
    `migrate_to_sl_batch = ${interval.migrateToGWBatchNumber}\n` +
    `migrate_from_sl_batch = ${interval.migrateFromGWBatchNumber}\n` +
    `sl_batch_lower_bound = ${interval.slBatchLowerBound}\n` +
    `sl_batch_upper_bound = ${interval.slBatchUpperBound}`
  );
}

// ─── Entry point ──────────────────────────────────────────────────────────────

async function main(): Promise<void> {
  const program = new Command();
  program.version("0.1.0").name("collect-gateway-migration-intervals");

  program
    .command("collect")
    .description(
      "Scan L1 for legacy-GW migration events and cache results to " +
        `script-out/<env>-${CACHE_FILE_SUFFIX}`
    )
    .requiredOption("--rpc <url>", "L1 RPC URL")
    .requiredOption("--env <name>", "Environment name: stage | testnet | mainnet")
    .action(async (cmd) => {
      await collect(cmd.rpc, cmd.env);
    });

  program
    .command("write")
    .description(
      `Read the cached JSON file and write [[legacy_gateway.chain_intervals]] entries ` +
        "into upgrade-envs/permanent-values/<env>.toml"
    )
    .requiredOption("--env <name>", "Environment name: stage | testnet | mainnet")
    .action((cmd) => {
      write(cmd.env);
    });

  await program.parseAsync(process.argv);
}

main()
  .then(() => process.exit(0))
  .catch((err: Error) => {
    console.error("Error:", err.message);
    process.exit(1);
  });

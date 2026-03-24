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
 *     MigrationFinalized events emitted by the L1ChainAssetHandler that
 *     involve the legacy ZK Gateway (settlementLayerChainId matches
 *     legacy_gateway.chain_id).
 *
 *     For each chain, historical state calls via the chain's diamond proxy
 *     Getters facet derive the four batch-number fields required by
 *     `MigrationInterval`:
 *       - migrateToGWBatchNumber   (L1 batch of the chain at migration-to time)
 *       - slBatchLowerBound        (GW batch at migration-to time)
 *       - migrateFromGWBatchNumber (GW batch of the chain at migration-from time)
 *       - slBatchUpperBound        (GW batch at migration-from time)
 *
 *     Results are cached in:
 *       script-out/<env>-gateway-migration-intervals.json
 *
 *     This file is git-ignored and can be regenerated at any time.
 *
 *   write --env <name>
 *     Reads the cached JSON file and writes [[legacy_gateway.chain_intervals]]
 *     entries into upgrade-envs/permanent-values/<env>.toml, replacing the
 *     existing TODO(EVM-1221) placeholder comment block.
 */

// eslint-disable-next-line @typescript-eslint/no-unused-vars
import * as hardhat from "hardhat";
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

// ─── Block iteration step ─────────────────────────────────────────────────────

const BLOCK_STEP = 10_000;

// ─── ABI loading from zkstack-out (committed artifacts) ──────────────────────

/**
 * Loads an ABI from a committed zkstack-out JSON file.
 * These files are flat arrays (not wrapped in {abi: [...]}).
 */
function loadZkstackAbi(relativeToZkstackOut: string): ethers.ContractInterface {
  const fullPath = path.join(__dirname, "..", "zkstack-out", relativeToZkstackOut);
  if (!fs.existsSync(fullPath)) {
    throw new Error(
      `zkstack-out ABI file not found: ${fullPath}\n` +
        "Ensure the zkstack-out directory is up to date."
    );
  }
  const data = JSON.parse(fs.readFileSync(fullPath, "utf-8"));
  return Array.isArray(data) ? data : (data as { abi: ethers.ContractInterface }).abi;
}

// Lazy-load ABIs at first use so the `write` command works without requiring
// zkstack-out to be present (it only reads committed TOML files).
let _bridgehubAbi: ethers.ContractInterface | null = null;
let _chainAssetHandlerAbi: ethers.ContractInterface | null = null;
let _zkChainAbi: ethers.ContractInterface | null = null;

function getBridgehubAbi(): ethers.ContractInterface {
  if (!_bridgehubAbi) {
    _bridgehubAbi = loadZkstackAbi("L1Bridgehub.sol/L1Bridgehub.json");
  }
  return _bridgehubAbi;
}

function getChainAssetHandlerAbi(): ethers.ContractInterface {
  if (!_chainAssetHandlerAbi) {
    _chainAssetHandlerAbi = loadZkstackAbi(
      "IChainAssetHandler.sol/IChainAssetHandlerBase.json"
    );
  }
  return _chainAssetHandlerAbi;
}

function getZKChainAbi(): ethers.ContractInterface {
  if (!_zkChainAbi) {
    _zkChainAbi = loadZkstackAbi("IZKChain.sol/IZKChain.json");
  }
  return _zkChainAbi;
}

// ─── Data types ───────────────────────────────────────────────────────────────

/** Snapshot of on-chain batch counters for a specific chain at a specific block. */
interface BatchSnapshot {
  blockNumber: number;
  totalBatchesExecuted: number;
  totalBatchesVerified: number;
  totalBatchesCommitted: number;
}

/** A single chain's completed legacy-GW migration interval. */
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

/** A single raw migration-related event captured during collection. */
interface RawEvent {
  type: "MigrationStarted" | "MigrationFinalized";
  chainId: number;
  migrationNumber: number;
  blockNumber: number;
  txHash: string;
}

/** The JSON cache format stored in script-out/. */
interface CollectedData {
  /** First block number scanned (block where GW diamond proxy was first deployed). */
  firstBlock: number;
  /** Last block number scanned (inclusive). */
  lastBlock: number;
  /** All raw migration events captured for this env. */
  events: RawEvent[];
  /** Derived complete intervals (one per chain). */
  intervals: ChainMigrationInterval[];
}

// ─── Binary search: find first block with deployed contract code ──────────────

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

// ─── Utility: read batch counters from a ZK chain diamond proxy at a block ───

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

  console.log(`Bridgehub:         ${bridgehubAddress}`);
  console.log(`Legacy GW chain:   ${legacyGwChainId}`);

  const provider = new ethers.providers.JsonRpcProvider(rpc);
  const bridgehub = new ethers.Contract(bridgehubAddress, getBridgehubAbi(), provider);

  const chainAssetHandlerAddress: string = await bridgehub.chainAssetHandler();
  console.log(`ChainAssetHandler: ${chainAssetHandlerAddress}`);

  const chainAssetHandler = new ethers.Contract(
    chainAssetHandlerAddress,
    getChainAssetHandlerAbi(),
    provider
  );

  // ── Determine scan range via binary search ─────────────────────────────────
  // Start scanning from the block at which the legacy GW's diamond proxy was
  // first deployed.  This avoids iterating the entire L1 history.

  const legacyGwDiamondProxy: string = await bridgehub.getZKChain(legacyGwChainId);
  console.log(`Legacy GW diamond: ${legacyGwDiamondProxy}`);

  const latestBlock = await provider.getBlockNumber();

  console.log(`\nBinary-searching for legacy GW deployment block…`);
  const firstBlock = await binarySearchDeployBlock(provider, legacyGwDiamondProxy, 0, latestBlock);
  console.log(`Legacy GW first deployed at block: ${firstBlock}`);
  console.log(`Scanning blocks ${firstBlock} – ${latestBlock} (step ${BLOCK_STEP})…\n`);

  // ── Build event filters ────────────────────────────────────────────────────

  // MigrationStarted: filter to events whose settlementLayerChainId == legacyGwChainId
  const startedFilter = chainAssetHandler.filters.MigrationStarted(
    null, // chainId – any
    null, // migrationNumber – not indexed, cannot filter
    null, // assetId – any
    ethers.BigNumber.from(legacyGwChainId) // settlementLayerChainId
  );

  // MigrationFinalized: collect all (we will pair by chainId + migrationNumber)
  const finalizedFilter = chainAssetHandler.filters.MigrationFinalized();

  // ── Single scan loop over all blocks ──────────────────────────────────────

  const allStarted: ethers.Event[] = [];
  const allFinalized: ethers.Event[] = [];

  for (let from = firstBlock; from <= latestBlock; from += BLOCK_STEP) {
    const to = Math.min(from + BLOCK_STEP - 1, latestBlock);

    const [startedChunk, finalizedChunk] = await Promise.all([
      chainAssetHandler.queryFilter(startedFilter, from, to),
      chainAssetHandler.queryFilter(finalizedFilter, from, to),
    ]);

    allStarted.push(...startedChunk);
    allFinalized.push(...finalizedChunk);

    if (startedChunk.length > 0 || finalizedChunk.length > 0) {
      console.log(
        `  blocks ${from}–${to}: +${startedChunk.length} MigrationStarted, +${finalizedChunk.length} MigrationFinalized`
      );
    }
  }

  console.log(
    `\nTotal: ${allStarted.length} MigrationStarted (to legacy GW), ${allFinalized.length} MigrationFinalized`
  );

  // ── Build lookup map for MigrationFinalized events ────────────────────────

  // Key: `${chainId}:${migrationNumber}`
  const finalizedByKey = new Map<string, ethers.Event>();
  for (const ev of allFinalized) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    const migNum = (ev.args!.migrationNumber as ethers.BigNumber).toNumber();
    finalizedByKey.set(`${chainId}:${migNum}`, ev);
  }

  // ── Build raw event list ───────────────────────────────────────────────────

  const rawEvents: RawEvent[] = [];

  for (const ev of allStarted) {
    rawEvents.push({
      type: "MigrationStarted",
      chainId: (ev.args!.chainId as ethers.BigNumber).toNumber(),
      migrationNumber: (ev.args!.migrationNumber as ethers.BigNumber).toNumber(),
      blockNumber: ev.blockNumber,
      txHash: ev.transactionHash,
    });
  }
  for (const ev of allFinalized) {
    rawEvents.push({
      type: "MigrationFinalized",
      chainId: (ev.args!.chainId as ethers.BigNumber).toNumber(),
      migrationNumber: (ev.args!.migrationNumber as ethers.BigNumber).toNumber(),
      blockNumber: ev.blockNumber,
      txHash: ev.transactionHash,
    });
  }

  // ── Pre-fetch diamond proxy addresses for all chains ──────────────────────

  const chainIds = Array.from(new Set(allStarted.map((ev) => (ev.args!.chainId as ethers.BigNumber).toNumber())));
  const diamondProxies = new Map<number, ethers.Contract>();

  // Always include the legacy GW itself
  const allChainIds = Array.from(new Set([...chainIds, legacyGwChainId]));

  for (const chainId of allChainIds) {
    const proxyAddr: string = await bridgehub.getZKChain(chainId);
    diamondProxies.set(chainId, new ethers.Contract(proxyAddr, getZKChainAbi(), provider));
    console.log(`  chain ${chainId} diamond proxy: ${proxyAddr}`);
  }

  const gwProxy = diamondProxies.get(legacyGwChainId)!;

  // ── Derive migration intervals ─────────────────────────────────────────────

  const intervals: ChainMigrationInterval[] = [];

  for (const ev of allStarted) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    const migrationNumber = (ev.args!.migrationNumber as ethers.BigNumber).toNumber();
    const startedBlock = ev.blockNumber;

    const chainProxy = diamondProxies.get(chainId)!;

    // The return migration has migrationNumber + 1
    const returnMigNum = migrationNumber + 1;
    const finalizedEv = finalizedByKey.get(`${chainId}:${returnMigNum}`);

    if (!finalizedEv) {
      console.log(
        `❌  chain ${chainId} (migrationNumber=${migrationNumber}) has NO MigrationFinalized return event — ` +
          `chain has not returned from the legacy GW yet`
      );
      continue;
    }

    const finalizedBlock = finalizedEv.blockNumber;

    console.log(`\n  chain ${chainId}: MigrationStarted block=${startedBlock}, MigrationFinalized block=${finalizedBlock}`);

    // Fetch all batch snapshots concurrently
    const [chainAtStart, gwAtStart, chainAtFinalized, gwAtFinalized] = await Promise.all([
      getBatchSnapshot(chainProxy, startedBlock),
      getBatchSnapshot(gwProxy, startedBlock),
      getBatchSnapshot(chainProxy, finalizedBlock),
      getBatchSnapshot(gwProxy, finalizedBlock),
    ]);

    console.log(
      `    migrateToGWBatch=${chainAtStart.totalBatchesExecuted}` +
        ` slLowerBound=${gwAtStart.totalBatchesExecuted}` +
        ` migrateFromGWBatch=${chainAtFinalized.totalBatchesExecuted}` +
        ` slUpperBound=${gwAtFinalized.totalBatchesExecuted}`
    );

    intervals.push({
      chainId,
      migrateToGWBatchNumber: chainAtStart.totalBatchesExecuted,
      migrateFromGWBatchNumber: chainAtFinalized.totalBatchesExecuted,
      slBatchLowerBound: gwAtStart.totalBatchesExecuted,
      slBatchUpperBound: gwAtFinalized.totalBatchesExecuted,
      snapshots: {
        chainAtMigrationStarted: chainAtStart,
        gwAtMigrationStarted: gwAtStart,
        chainAtMigrationFinalized: chainAtFinalized,
        gwAtMigrationFinalized: gwAtFinalized,
      },
    });
  }

  // ── Persist to JSON cache ─────────────────────────────────────────────────

  const output: CollectedData = {
    firstBlock,
    lastBlock: latestBlock,
    events: rawEvents,
    intervals,
  };

  if (!fs.existsSync(SCRIPT_OUT_DIR)) {
    fs.mkdirSync(SCRIPT_OUT_DIR, { recursive: true });
  }

  const outFile = path.join(SCRIPT_OUT_DIR, `${envName}-gateway-migration-intervals.json`);
  fs.writeFileSync(outFile, JSON.stringify(output, null, 2));

  console.log(`\nFound ${intervals.length} completed legacy-GW migration interval(s).`);
  console.log(`Saved to: ${outFile}`);
}

// ─── write command ────────────────────────────────────────────────────────────

function write(envName: string): void {
  const cacheFile = path.join(SCRIPT_OUT_DIR, `${envName}-gateway-migration-intervals.json`);

  if (!fs.existsSync(cacheFile)) {
    throw new Error(
      `Cache file not found: ${cacheFile}\n` +
        `Run: yarn collect-gateway-migration-intervals collect --rpc <RPC_URL> --env ${envName}`
    );
  }

  const data: CollectedData = JSON.parse(fs.readFileSync(cacheFile, "utf-8"));

  if (data.intervals.length === 0) {
    console.log(`No completed legacy-GW migration intervals found in ${cacheFile} – nothing to write.`);
    return;
  }

  const permanentValuesFile = path.join(PERMANENT_VALUES_DIR, `${envName}.toml`);

  if (!fs.existsSync(permanentValuesFile)) {
    throw new Error(`Permanent values file not found: ${permanentValuesFile}`);
  }

  let content = fs.readFileSync(permanentValuesFile, "utf-8");

  // Guard: if chain_intervals are already present, refuse to overwrite.
  if (content.includes("[[legacy_gateway.chain_intervals]]")) {
    console.warn(
      `WARNING: ${permanentValuesFile} already contains [[legacy_gateway.chain_intervals]] entries.\n` +
        "Remove them manually before re-running write."
    );
    return;
  }

  // Remove the TODO(EVM-1221) placeholder comment block.
  // The block starts with the TODO comment and consists of comment lines only.
  content = content.replace(/\n# TODO\(EVM-1221\)[\s\S]*$/, "");

  // Append the derived chain intervals.
  const entries = data.intervals.map((interval) => serializeChainInterval(interval)).join("\n");

  content = content.trimEnd() + "\n\n" + entries + "\n";

  fs.writeFileSync(permanentValuesFile, content);

  console.log(`Wrote ${data.intervals.length} chain interval(s) to ${permanentValuesFile}`);
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

function serializeChainInterval(interval: ChainMigrationInterval): string {
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
      "Scan L1 events to collect legacy ZK Gateway migration intervals and cache them in " +
        "script-out/<env>-gateway-migration-intervals.json"
    )
    .requiredOption("--rpc <url>", "L1 RPC URL to query")
    .requiredOption("--env <name>", "Environment name: stage | testnet | mainnet")
    .action(async (cmd) => {
      await collect(cmd.rpc, cmd.env);
    });

  program
    .command("write")
    .description(
      "Read the cached JSON file and write [[legacy_gateway.chain_intervals]] entries " +
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

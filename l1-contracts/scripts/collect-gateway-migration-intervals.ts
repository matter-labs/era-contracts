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

  const chainAssetHandler = new ethers.Contract(
    chainAssetHandlerAddress,
    LEGACY_CHAIN_ASSET_HANDLER_ABI,
    provider
  );

  // ── Determine scan start block ────────────────────────────────────────────
  // Find the first block at which the legacy GW's diamond proxy has code.
  // This avoids scanning all of L1 history.

  const legacyGwDiamondProxy: string = await bridgehub.getZKChain(legacyGwChainId);
  console.log(`Legacy GW proxy: ${legacyGwDiamondProxy}`);

  const latestBlock = await provider.getBlockNumber();

  console.log("\nBinary-searching for legacy GW deployment block…");
  const firstBlock = await binarySearchDeployBlock(provider, legacyGwDiamondProxy, 0, latestBlock);
  console.log(`Legacy GW deployed at block: ${firstBlock}`);
  console.log(`Scanning ${firstBlock} – ${latestBlock} in ${BLOCK_STEP}-block chunks…\n`);

  // ── Single scan loop ──────────────────────────────────────────────────────
  // Collect all MigrationStarted and MigrationFinalized events in one pass.

  const startedFilter = chainAssetHandler.filters.MigrationStarted();
  const finalizedFilter = chainAssetHandler.filters.MigrationFinalized();

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

    console.log(
      `  blocks ${from}–${to}: +${startedChunk.length} MigrationStarted, +${finalizedChunk.length} MigrationFinalized`
    );
  }

  console.log(
    `\nTotal: ${allStarted.length} MigrationStarted, ${allFinalized.length} MigrationFinalized`
  );

  // ── Validate that all MigrationStarted events targeted the legacy GW ─────

  for (const ev of allStarted) {
    const slChainId = (ev.args!.settlementLayerChainId as ethers.BigNumber).toNumber();
    if (slChainId !== legacyGwChainId) {
      console.warn(
        `  WARNING: MigrationStarted at block ${ev.blockNumber} targets chainId ${slChainId}, ` +
          `not the legacy GW (${legacyGwChainId}) — skipping`
      );
    }
  }

  // ── Build MigrationFinalized lookup (by chainId) ──────────────────────────
  // Assert there is at most one MigrationFinalized per chain — duplicates would
  // indicate unexpected on-chain state and the script cannot reliably derive
  // intervals from ambiguous data.

  const finalizedByChainId = new Map<number, ethers.Event>();
  for (const ev of allFinalized) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    if (finalizedByChainId.has(chainId)) {
      throw new Error(
        `Unexpected duplicate MigrationFinalized for chain ${chainId} ` +
          `(blocks ${finalizedByChainId.get(chainId)!.blockNumber} and ${ev.blockNumber})`
      );
    }
    finalizedByChainId.set(chainId, ev);
  }

  // ── Pre-fetch diamond proxy contracts for each chain ──────────────────────

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

  // ── Derive intervals ──────────────────────────────────────────────────────
  // Simple rule: MigrationStarted → remember state; MigrationFinalized → close interval.
  // If a chain has no MigrationFinalized by the end, log an error.

  const intervals: ChainMigrationInterval[] = [];

  // Track chains for which we have seen MigrationStarted but not yet Finalized.
  // Assert at most one MigrationStarted per chain targeting the legacy GW.
  const pendingChains = new Map<number, { startedBlock: number }>();

  for (const ev of allStarted) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    const slChainId = (ev.args!.settlementLayerChainId as ethers.BigNumber).toNumber();
    if (slChainId !== legacyGwChainId) continue;

    if (pendingChains.has(chainId)) {
      throw new Error(
        `Unexpected duplicate MigrationStarted (to legacy GW) for chain ${chainId} ` +
          `(blocks ${pendingChains.get(chainId)!.startedBlock} and ${ev.blockNumber})`
      );
    }
    pendingChains.set(chainId, { startedBlock: ev.blockNumber });
  }

  for (const [chainId, { startedBlock }] of pendingChains) {
    const finalizedEv = finalizedByChainId.get(chainId);

    if (!finalizedEv) {
      console.log(
        `❌  chain ${chainId} has NOT returned from the legacy GW — no MigrationFinalized event found`
      );
      continue;
    }

    const finalizedBlock = finalizedEv.blockNumber;
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

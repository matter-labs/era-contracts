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
 *     For each chain, historical state calls derive the four batch-number
 *     fields required by `MigrationInterval`:
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

// ─── Inline ABIs ─────────────────────────────────────────────────────────────
//
// These minimal ABIs are defined inline so that the `write` command works on a
// clean checkout without requiring `forge build`.  The `collect` command also
// uses these (augmented by the on-chain data).

const BRIDGEHUB_ABI = [
  "function chainAssetHandler() external view returns (address)",
  "function messageRoot() external view returns (address)",
];

const CHAIN_ASSET_HANDLER_ABI = [
  // Events
  "event MigrationStarted(uint256 indexed chainId, uint256 migrationNumber, bytes32 indexed assetId, uint256 indexed settlementLayerChainId)",
  "event MigrationFinalized(uint256 indexed chainId, uint256 migrationNumber, bytes32 indexed assetId, address indexed zkChain)",
];

const MESSAGE_ROOT_ABI = [
  "function currentChainBatchNumber(uint256 chainId) external view returns (uint256)",
];

// ─── Data types ───────────────────────────────────────────────────────────────

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
  /** First block number scanned. */
  firstBlock: number;
  /** Last block number scanned (inclusive). */
  lastBlock: number;
  /** All raw migration events captured for this env. */
  events: RawEvent[];
  /** Derived complete intervals (one per chain). */
  intervals: ChainMigrationInterval[];
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
  const bridgehub = new ethers.Contract(bridgehubAddress, BRIDGEHUB_ABI, provider);

  const chainAssetHandlerAddress: string = await bridgehub.chainAssetHandler();
  const messageRootAddress: string = await bridgehub.messageRoot();

  console.log(`ChainAssetHandler: ${chainAssetHandlerAddress}`);
  console.log(`MessageRoot:       ${messageRootAddress}`);

  const chainAssetHandler = new ethers.Contract(
    chainAssetHandlerAddress,
    CHAIN_ASSET_HANDLER_ABI,
    provider
  );
  const messageRoot = new ethers.Contract(messageRootAddress, MESSAGE_ROOT_ABI, provider);

  const latestBlock = await provider.getBlockNumber();
  const firstBlock = 0;

  console.log(`\nScanning blocks ${firstBlock} – ${latestBlock} …`);

  // ── Collect MigrationStarted events (TO legacy GW) ────────────────────────

  // The third indexed topic on MigrationStarted is settlementLayerChainId.
  // Filter directly so we only fetch events destined for the legacy GW.
  const startedFilter = chainAssetHandler.filters.MigrationStarted(
    null, // chainId – any
    null, // migrationNumber – not indexed, cannot filter
    null, // assetId – any
    ethers.BigNumber.from(legacyGwChainId) // settlementLayerChainId
  );

  const startedEvents = await chainAssetHandler.queryFilter(startedFilter, firstBlock, latestBlock);
  console.log(`  MigrationStarted (to legacy GW): ${startedEvents.length} event(s)`);

  // Build a map: chainId → list of (migrationNumber, blockNumber, txHash)
  type StartedInfo = { migrationNumber: number; blockNumber: number; txHash: string };
  const startedByChain = new Map<number, StartedInfo[]>();

  for (const ev of startedEvents) {
    const chainId = (ev.args!.chainId as ethers.BigNumber).toNumber();
    const migNum = (ev.args!.migrationNumber as ethers.BigNumber).toNumber();
    const entry: StartedInfo = {
      migrationNumber: migNum,
      blockNumber: ev.blockNumber,
      txHash: ev.transactionHash,
    };
    if (!startedByChain.has(chainId)) {
      startedByChain.set(chainId, []);
    }
    startedByChain.get(chainId)!.push(entry);
  }

  // ── Collect MigrationFinalized events (back to L1 from legacy GW) ─────────

  // MigrationFinalized is emitted on L1 when a chain returns from a settlement layer.
  // We only care about chains that previously started a migration to the legacy GW.
  const chainIdsToWatch = Array.from(startedByChain.keys());

  const rawEvents: RawEvent[] = [];

  // Record MigrationStarted events
  for (const ev of startedEvents) {
    rawEvents.push({
      type: "MigrationStarted",
      chainId: (ev.args!.chainId as ethers.BigNumber).toNumber(),
      migrationNumber: (ev.args!.migrationNumber as ethers.BigNumber).toNumber(),
      blockNumber: ev.blockNumber,
      txHash: ev.transactionHash,
    });
  }

  const intervals: ChainMigrationInterval[] = [];

  // For each chain that had a MigrationStarted event to legacy GW, look for a
  // corresponding MigrationFinalized event on L1 (chain returned from legacy GW).
  for (const chainId of chainIdsToWatch) {
    const startedList = startedByChain.get(chainId)!;

    for (const started of startedList) {
      // The MigrationFinalized event for the return trip has the same chainId and
      // migrationNumber + 1 (outgoing = N, incoming = N+1 per the MIGRATION_NUMBER_* constants).
      const expectedReturnMigNum = started.migrationNumber + 1;

      const finalizedFilter = chainAssetHandler.filters.MigrationFinalized(
        ethers.BigNumber.from(chainId), // chainId (indexed)
        null, // migrationNumber (not indexed)
        null, // assetId (indexed)
        null  // zkChain (indexed)
      );

      const finalizedEvents = await chainAssetHandler.queryFilter(
        finalizedFilter,
        started.blockNumber, // only look after the MigrationStarted block
        latestBlock
      );

      // Find the one with the matching migration number
      const matchingFinalized = finalizedEvents.find(
        (ev) => (ev.args!.migrationNumber as ethers.BigNumber).toNumber() === expectedReturnMigNum
      );

      // Record all MigrationFinalized events for this chain
      for (const ev of finalizedEvents) {
        rawEvents.push({
          type: "MigrationFinalized",
          chainId: (ev.args!.chainId as ethers.BigNumber).toNumber(),
          migrationNumber: (ev.args!.migrationNumber as ethers.BigNumber).toNumber(),
          blockNumber: ev.blockNumber,
          txHash: ev.transactionHash,
        });
      }

      // ── Derive batch numbers via historical state calls ───────────────────

      // migrateToGWBatchNumber:
      //   The L1 MessageRoot records the current batch number for each chain.
      //   At the MigrationStarted block, currentChainBatchNumber(chainId) is the
      //   last L1 batch of the chain before it moved to the legacy GW.
      const migrateToGWBatchNumber = await callAtBlock<ethers.BigNumber>(
        messageRoot,
        "currentChainBatchNumber",
        [chainId],
        started.blockNumber
      );

      // slBatchLowerBound:
      //   The legacy GW's own batch number at the time the chain migrated TO it.
      const slBatchLowerBound = await callAtBlock<ethers.BigNumber>(
        messageRoot,
        "currentChainBatchNumber",
        [legacyGwChainId],
        started.blockNumber
      );

      console.log(
        `  chain ${chainId} MigrationStarted block=${started.blockNumber}` +
          ` migrateToGWBatch=${migrateToGWBatchNumber.toString()}` +
          ` slLowerBound=${slBatchLowerBound.toString()}`
      );

      if (!matchingFinalized) {
        // Chain is still on the legacy GW (active migration) – skip; the
        // setHistoricalMigrationInterval function only accepts completed intervals.
        console.log(
          `  chain ${chainId} has no MigrationFinalized return event – still active on legacy GW, skipping`
        );
        continue;
      }

      // migrateFromGWBatchNumber:
      //   After bridgeMint is called on L1 for the returning chain, the MessageRoot's
      //   currentChainBatchNumber(chainId) is set to the GW batch that was packed into
      //   the mint data (via setMigratingChainBatchNumber).  Reading it at the
      //   MigrationFinalized block gives us the exact GW batch.
      const migrateFromGWBatchNumber = await callAtBlock<ethers.BigNumber>(
        messageRoot,
        "currentChainBatchNumber",
        [chainId],
        matchingFinalized.blockNumber
      );

      // slBatchUpperBound:
      //   The legacy GW's own batch number at the time the chain migrated FROM it.
      const slBatchUpperBound = await callAtBlock<ethers.BigNumber>(
        messageRoot,
        "currentChainBatchNumber",
        [legacyGwChainId],
        matchingFinalized.blockNumber
      );

      console.log(
        `  chain ${chainId} MigrationFinalized block=${matchingFinalized.blockNumber}` +
          ` migrateFromGWBatch=${migrateFromGWBatchNumber.toString()}` +
          ` slUpperBound=${slBatchUpperBound.toString()}`
      );

      intervals.push({
        chainId,
        migrateToGWBatchNumber: migrateToGWBatchNumber.toNumber(),
        migrateFromGWBatchNumber: migrateFromGWBatchNumber.toNumber(),
        slBatchLowerBound: slBatchLowerBound.toNumber(),
        slBatchUpperBound: slBatchUpperBound.toNumber(),
      });
    }
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

// ─── Utility: call a view function at a specific historical block ─────────────

async function callAtBlock<T>(
  contract: ethers.Contract,
  method: string,
  args: unknown[],
  blockNumber: number
): Promise<T> {
  return contract.callStatic[method](...args, { blockTag: blockNumber }) as Promise<T>;
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
  const entries = data.intervals
    .map((interval) => serializeChainInterval(interval))
    .join("\n");

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
  program
    .version("0.1.0")
    .name("collect-gateway-migration-intervals");

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

#!/usr/bin/env ts-node
/**
 * Discover every L1 ERC20 ever deposited into the ZKsync bridges, so that
 * v31 stage3 (`CoreUpgrade_v31.stage3` → `registerBridgedTokensInNTV`) has the
 * full set of legacy token addresses to seed `NTV.bridgedTokens`.
 *
 * Sources scanned (output is the union, deduped and checksummed):
 *
 *   - L1AssetRouter.LegacyDepositInitiated(chainId, l2DepositTxHash, from, to,
 *       l1Token, amount) — legacy ERC20 deposits routed through the asset
 *     router (post-AR-deploy but pre-asset-id era).
 *   - L1AssetRouter.BridgehubDepositInitiated(chainId, txDataHash, from,
 *       assetId, bridgeMintCalldata) — asset-id era deposits. Only `assetId`
 *     is on the log; we resolve to an L1 address via
 *     `L1NativeTokenVault.tokenAddress(assetId)` (skipped if the address
 *     comes back zero — that means the asset is not native to L1).
 *   - L1ERC20Bridge.DepositInitiated(l2DepositTxHash, from, to, l1Token,
 *       amount) — pre-AssetRouter deposits straight against the old shared
 *       bridge.
 *
 * Usage:
 *
 *   discover --env <name> --rpc <url> [--from-block <n>] [--to-block <n>]
 *            [--block-step <n>] [--out <path>]
 *
 *     Reads `core_contracts.bridgehub_proxy_addr` from
 *     `upgrade-envs/permanent-values/<env>.toml`, resolves AssetRouter,
 *     NativeTokenVault and L1ERC20Bridge on-chain, scans logs over the
 *     supplied (or full-history) block range, and writes the deduped,
 *     EIP-55-checksummed token list to `--out` (default
 *     `upgrade-envs/v0.31.0-interopB/<env>-bridged-tokens.toml`).
 *
 * Output schema mirrors what `TokenMigrationUtils._readConfiguredBridgedTokens`
 * expects (`[tokens] bridged_tokens = ["0x..", …]`), so the same file feeds
 * stage3 directly once it's pointed at the per-env path.
 *
 * Prerequisites:
 *   Run `forge build` in l1-contracts/ to generate ABI files under `out/`.
 */

import * as fs from "fs";
import * as path from "path";
import { ethers } from "ethers";
import { Command } from "commander";
import { getBridgehubAddress, loadAbiFromFoundryOutput } from "./upgrade-script-utils";

// ─── Paths / constants ────────────────────────────────────────────────────

/** Default destination dir for the per-env tokens file. */
// Historical: this script discovers the *legacy* bridged tokens the v31 upgrade registered, so
// its output belongs with that release's inputs. v33 has no bridged-token registration step.
const LEGACY_UPGRADE_DIR = path.join(__dirname, "../upgrade-envs/v0.31.0-interopB");

/** Conservative default — covers most public RPCs without log-size pushback. */
const DEFAULT_BLOCK_STEP = 10_000;

// Minimal inline ABIs only for the bridgehub getter we need before any
// foundry-output ABI is loaded. Once we have the bridgehub we read the
// fuller ABIs from foundry-output JSON.
const BRIDGEHUB_GETTER_ABI = ["function assetRouter() view returns (address)"];
const ASSET_ROUTER_GETTER_ABI = [
  "function nativeTokenVault() view returns (address)",
  "function legacyBridge() view returns (address)",
];

// Event topics we scan. We don't need the full contract ABI — each
// `Interface` only needs to know the event signature so it can compute the
// topic hash and decode the log. Decoupling these from the foundry ABIs
// keeps the script working even when only some out/ folders are present.
const ASSET_ROUTER_EVENTS_ABI = [
  "event LegacyDepositInitiated(uint256 indexed chainId, bytes32 indexed l2DepositTxHash, address indexed from, address to, address l1Token, uint256 amount)",
  "event BridgehubDepositInitiated(uint256 indexed chainId, bytes32 indexed txDataHash, address indexed from, bytes32 assetId, bytes bridgeMintCalldata)",
];
const ERC20_BRIDGE_EVENTS_ABI = [
  "event DepositInitiated(bytes32 indexed l2DepositTxHash, address indexed from, address indexed to, address l1Token, uint256 amount)",
];

// Lazy-loaded only because `tokenAddress(bytes32)` for asset-id resolution
// is the one call we genuinely need full NTV ABI for.
const NTV_TOKEN_ADDRESS_ABI = ["function tokenAddress(bytes32) view returns (address)"];

// `address(1)` is the ETH sentinel in `contracts/common/Config.sol`
// (`ETH_TOKEN_ADDRESS`). stage3's `registerBridgedTokensInNTV` always
// prepends ETH to the registration list, so we drop it from the discovered
// set to avoid the redundant entry.
const ETH_TOKEN_ADDRESS = "0x0000000000000000000000000000000000000001";

// ─── Types ────────────────────────────────────────────────────────────────

interface ResolvedAddresses {
  bridgehub: string;
  assetRouter: string;
  nativeTokenVault: string;
  legacyErc20Bridge: string | null; // null if AR.legacyBridge() returns 0
}

interface DiscoveryResult {
  /** Checksummed addresses, sorted lexicographically for stable diffs. */
  tokens: string[];
  /** Block range actually scanned. */
  fromBlock: number;
  toBlock: number;
  /** Per-source counts, for the run summary. */
  counts: {
    legacyDepositInitiated: number;
    bridgehubDepositInitiated: number;
    erc20BridgeDepositInitiated: number;
    assetIdsResolved: number;
    assetIdsSkippedNonL1Native: number;
  };
}

// ─── Resolution ───────────────────────────────────────────────────────────

async function resolveAddresses(provider: ethers.providers.Provider, bridgehub: string): Promise<ResolvedAddresses> {
  const bh = new ethers.Contract(bridgehub, BRIDGEHUB_GETTER_ABI, provider);
  const assetRouter: string = await bh.assetRouter();
  if (assetRouter === ethers.constants.AddressZero) {
    throw new Error(`Bridgehub ${bridgehub} returned zero address for assetRouter()`);
  }

  const ar = new ethers.Contract(assetRouter, ASSET_ROUTER_GETTER_ABI, provider);
  const nativeTokenVault: string = await ar.nativeTokenVault();
  if (nativeTokenVault === ethers.constants.AddressZero) {
    throw new Error(`AssetRouter ${assetRouter} returned zero address for nativeTokenVault()`);
  }

  // legacyBridge can legitimately be address(0) on envs without a pre-AR
  // bridge (e.g. testnet's ZKsyncOS deployment). Treat that as "no events to
  // scan from this contract" rather than an error.
  let legacyBridge: string | null = await ar.legacyBridge();
  if (legacyBridge === ethers.constants.AddressZero) {
    legacyBridge = null;
  }

  return {
    bridgehub: ethers.utils.getAddress(bridgehub),
    assetRouter: ethers.utils.getAddress(assetRouter),
    nativeTokenVault: ethers.utils.getAddress(nativeTokenVault),
    legacyErc20Bridge: legacyBridge ? ethers.utils.getAddress(legacyBridge) : null,
  };
}

// ─── Log scanning ─────────────────────────────────────────────────────────

interface ScanInput {
  provider: ethers.providers.JsonRpcProvider;
  fromBlock: number;
  toBlock: number;
  blockStep: number;
  address: string;
  topics: (string | null)[];
}

/**
 * Paginated `eth_getLogs` over [fromBlock, toBlock]. Halves the window on
 * RPC errors (most public RPCs return "log query exceeds max results" or
 * similar) until each chunk fits.
 */
async function getLogsPaginated({
  provider,
  fromBlock,
  toBlock,
  blockStep,
  address,
  topics,
}: ScanInput): Promise<ethers.providers.Log[]> {
  const out: ethers.providers.Log[] = [];

  let cursor = fromBlock;
  let step = blockStep;
  while (cursor <= toBlock) {
    const end = Math.min(cursor + step - 1, toBlock);
    try {
      const logs = await provider.getLogs({
        address,
        topics,
        fromBlock: cursor,
        toBlock: end,
      });
      out.push(...logs);
      cursor = end + 1;
      // Gently grow the window back after a successful chunk so we don't
      // stay stuck at a tiny step after a single transient failure.
      step = Math.min(step * 2, blockStep);
    } catch (err) {
      if (step <= 1) {
        throw new Error(
          `getLogs failed at block ${cursor} with step=1; address=${address} topic0=${
            topics[0] ?? "*"
          }: ${err instanceof Error ? err.message : String(err)}`
        );
      }
      step = Math.max(1, Math.floor(step / 2));
      // Don't advance cursor — retry the same starting block at the
      // smaller window size.
    }
  }
  return out;
}

// ─── Discovery core ───────────────────────────────────────────────────────

async function discover({
  rpcUrl,
  bridgehub,
  fromBlockArg,
  toBlockArg,
  blockStep,
}: {
  rpcUrl: string;
  bridgehub: string;
  fromBlockArg: number | null;
  toBlockArg: number | null;
  blockStep: number;
}): Promise<{ result: DiscoveryResult; resolved: ResolvedAddresses }> {
  const provider = new ethers.providers.JsonRpcProvider(rpcUrl);
  const resolved = await resolveAddresses(provider, bridgehub);

  const latest = await provider.getBlockNumber();
  const fromBlock = fromBlockArg ?? 0;
  const toBlock = toBlockArg ?? latest;

  if (fromBlock > toBlock) {
    throw new Error(`Invalid block range: fromBlock=${fromBlock} > toBlock=${toBlock}`);
  }

  console.log("Discovery plan:");
  console.log(`  RPC URL:            ${rpcUrl}`);
  console.log(`  Bridgehub:          ${resolved.bridgehub}`);
  console.log(`  AssetRouter:        ${resolved.assetRouter}`);
  console.log(`  NativeTokenVault:   ${resolved.nativeTokenVault}`);
  console.log(`  L1ERC20Bridge:      ${resolved.legacyErc20Bridge ?? "<none>"}`);
  console.log(`  Block range:        [${fromBlock}, ${toBlock}] (latest=${latest})`);
  console.log(`  Initial block step: ${blockStep}`);

  const arIface = new ethers.utils.Interface(ASSET_ROUTER_EVENTS_ABI);
  const erc20Iface = new ethers.utils.Interface(ERC20_BRIDGE_EVENTS_ABI);
  const ntv = new ethers.Contract(resolved.nativeTokenVault, NTV_TOKEN_ADDRESS_ABI, provider);

  const tokens = new Set<string>();
  const counts = {
    legacyDepositInitiated: 0,
    bridgehubDepositInitiated: 0,
    erc20BridgeDepositInitiated: 0,
    assetIdsResolved: 0,
    assetIdsSkippedNonL1Native: 0,
  };

  // ── 1. AssetRouter.LegacyDepositInitiated ────────────────────────────
  const legacyDepositTopic = arIface.getEventTopic("LegacyDepositInitiated");
  console.log("\n[1/3] AssetRouter.LegacyDepositInitiated...");
  const legacyDepositLogs = await getLogsPaginated({
    provider,
    fromBlock,
    toBlock,
    blockStep,
    address: resolved.assetRouter,
    topics: [legacyDepositTopic],
  });
  for (const log of legacyDepositLogs) {
    const parsed = arIface.parseLog(log);
    tokens.add(ethers.utils.getAddress(parsed.args.l1Token));
    counts.legacyDepositInitiated += 1;
  }
  console.log(`  scanned: ${legacyDepositLogs.length} logs, unique tokens so far: ${tokens.size}`);

  // ── 2. AssetRouter.BridgehubDepositInitiated (resolve assetIds via NTV)
  const bridgehubDepositTopic = arIface.getEventTopic("BridgehubDepositInitiated");
  console.log("\n[2/3] AssetRouter.BridgehubDepositInitiated...");
  const bridgehubDepositLogs = await getLogsPaginated({
    provider,
    fromBlock,
    toBlock,
    blockStep,
    address: resolved.assetRouter,
    topics: [bridgehubDepositTopic],
  });
  counts.bridgehubDepositInitiated = bridgehubDepositLogs.length;

  const assetIds = new Set<string>();
  for (const log of bridgehubDepositLogs) {
    const parsed = arIface.parseLog(log);
    assetIds.add(parsed.args.assetId);
  }
  console.log(`  scanned: ${bridgehubDepositLogs.length} logs, unique assetIds: ${assetIds.size}`);

  for (const assetId of assetIds) {
    // `tokenAddress(assetId)` returns address(0) for assets not native to
    // L1 (e.g. L2-origin tokens). Those don't need to be in the L1 stage3
    // bridged-tokens list — they're handled separately by the chain-side
    // upgrade flow.
    const tokenAddress: string = await ntv.tokenAddress(assetId);
    if (tokenAddress === ethers.constants.AddressZero) {
      counts.assetIdsSkippedNonL1Native += 1;
      continue;
    }
    tokens.add(ethers.utils.getAddress(tokenAddress));
    counts.assetIdsResolved += 1;
  }
  console.log(
    `  resolved: ${counts.assetIdsResolved} addresses, skipped ${counts.assetIdsSkippedNonL1Native} non-L1-native; unique tokens so far: ${tokens.size}`
  );

  // ── 3. L1ERC20Bridge.DepositInitiated (if a legacy bridge exists) ────
  console.log("\n[3/3] L1ERC20Bridge.DepositInitiated...");
  if (resolved.legacyErc20Bridge) {
    const erc20DepositTopic = erc20Iface.getEventTopic("DepositInitiated");
    const erc20DepositLogs = await getLogsPaginated({
      provider,
      fromBlock,
      toBlock,
      blockStep,
      address: resolved.legacyErc20Bridge,
      topics: [erc20DepositTopic],
    });
    for (const log of erc20DepositLogs) {
      const parsed = erc20Iface.parseLog(log);
      tokens.add(ethers.utils.getAddress(parsed.args.l1Token));
      counts.erc20BridgeDepositInitiated += 1;
    }
    console.log(`  scanned: ${erc20DepositLogs.length} logs, unique tokens so far: ${tokens.size}`);
  } else {
    console.log("  skipped: no L1ERC20Bridge wired on this env");
  }

  // Make sure the foundry-output ABI is at least present so callers know
  // the script was run against a current build (it isn't used at runtime,
  // but loading lazily here gives a clear error if `forge build` was
  // skipped before invoking this script against a real RPC).
  loadAbiFromFoundryOutput("../out/IL1NativeTokenVault.sol/IL1NativeTokenVault.json");

  // Drop ETH_TOKEN_ADDRESS — stage3 registers ETH unconditionally before
  // walking the configured list, so leaving address(1) in here would just
  // emit a "Token already present in bridged tokens list, skipping" log
  // during stage3.
  tokens.delete(ethers.utils.getAddress(ETH_TOKEN_ADDRESS));

  const sorted = Array.from(tokens).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
  return {
    result: {
      tokens: sorted,
      fromBlock,
      toBlock,
      counts,
    },
    resolved,
  };
}

// ─── Output ──────────────────────────────────────────────────────────────

function writeTomlOutput(filePath: string, env: string, result: DiscoveryResult, resolved: ResolvedAddresses): void {
  const dir = path.dirname(filePath);
  if (!fs.existsSync(dir)) fs.mkdirSync(dir, { recursive: true });

  const header = [
    "# Generated by scripts/discover-legacy-bridged-tokens.ts",
    `# Env:               ${env}`,
    `# Bridgehub:         ${resolved.bridgehub}`,
    `# AssetRouter:       ${resolved.assetRouter}`,
    `# NativeTokenVault:  ${resolved.nativeTokenVault}`,
    `# L1ERC20Bridge:     ${resolved.legacyErc20Bridge ?? "<none>"}`,
    `# Block range:       [${result.fromBlock}, ${result.toBlock}]`,
    "# Sources:",
    `#   AssetRouter.LegacyDepositInitiated:     ${result.counts.legacyDepositInitiated}`,
    `#   AssetRouter.BridgehubDepositInitiated:  ${result.counts.bridgehubDepositInitiated} logs => ${result.counts.assetIdsResolved} L1-native (${result.counts.assetIdsSkippedNonL1Native} non-L1-native skipped)`,
    `#   L1ERC20Bridge.DepositInitiated:         ${result.counts.erc20BridgeDepositInitiated}`,
    `# Unique L1-native tokens: ${result.tokens.length}`,
    "",
  ].join("\n");

  const body =
    result.tokens.length === 0
      ? "[tokens]\nbridged_tokens = []\n"
      : "[tokens]\nbridged_tokens = [\n" + result.tokens.map((t) => `  "${t}",`).join("\n") + "\n]\n";

  fs.writeFileSync(filePath, header + body);
  console.log(`\nWrote ${result.tokens.length} token(s) to: ${filePath}`);
}

// ─── CLI ─────────────────────────────────────────────────────────────────

function defaultOutPath(envName: string): string {
  return path.join(LEGACY_UPGRADE_DIR, `${envName}-bridged-tokens.toml`);
}

async function main(): Promise<void> {
  const program = new Command();

  program
    .name("discover-legacy-bridged-tokens")
    .description("Scan L1 deposit events and write the v31 stage3 bridged-tokens TOML.");

  program
    .command("discover")
    .description("Scan deposit events and write the per-env bridged-tokens TOML.")
    .requiredOption("--env <name>", "Env name (matches upgrade-envs/permanent-values/<env>.toml)")
    .requiredOption("--rpc <url>", "L1 RPC URL")
    .option("--from-block <n>", "Starting block (default 0 — full history)", (v) => parseInt(v, 10))
    .option("--to-block <n>", "Ending block (default: latest)", (v) => parseInt(v, 10))
    .option(
      "--block-step <n>",
      `Initial getLogs window size (default ${DEFAULT_BLOCK_STEP}; halves on RPC errors)`,
      (v) => parseInt(v, 10),
      DEFAULT_BLOCK_STEP
    )
    .option("--out <path>", "Output TOML path (default: upgrade-envs/v0.31.0-interopB/<env>-bridged-tokens.toml)")
    .action(
      async (opts: {
        env: string;
        rpc: string;
        fromBlock?: number;
        toBlock?: number;
        blockStep: number;
        out?: string;
      }) => {
        const bridgehub = getBridgehubAddress(opts.env);
        const outPath = opts.out ?? defaultOutPath(opts.env);

        const { result, resolved } = await discover({
          rpcUrl: opts.rpc,
          bridgehub,
          fromBlockArg: opts.fromBlock ?? null,
          toBlockArg: opts.toBlock ?? null,
          blockStep: opts.blockStep,
        });

        writeTomlOutput(outPath, opts.env, result, resolved);
      }
    );

  await program.parseAsync(process.argv);
}

main().catch((err) => {
  console.error(err instanceof Error ? (err.stack ?? err.message) : err);
  process.exit(1);
});

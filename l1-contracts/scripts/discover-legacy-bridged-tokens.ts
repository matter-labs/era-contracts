#!/usr/bin/env ts-node
/**
 * Discover every token with a legacy (pre-v31) entry in the L1
 * NativeTokenVault, so that v31 stage3 (`CoreUpgrade_v31.stage3` →
 * `registerBridgedTokensInNTV` → `registerAllLegacyTokens`) has the full set
 * of legacy token addresses to seed `NTV.bridgedTokens` and register on the
 * L1AssetTracker.
 *
 * Anything with an NTV entry that is missing from this list stays invisible
 * to `registerAllLegacyTokens` (it only iterates `NTV.bridgedTokens`) and
 * will revert post-upgrade with `AssetIdNotRegistered` on deposits and
 * `AssetNotMigratedFromNTV` on withdrawal finalization.
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
 *     comes back zero — that means the asset never materialized on L1).
 *   - L1ERC20Bridge.DepositInitiated(l2DepositTxHash, from, to, l1Token,
 *       amount) — pre-AssetRouter deposits straight against the old shared
 *       bridge.
 *   - L1NativeTokenVault.BridgeMint/BridgeBurn(chainId, assetId, ...) — every
 *     asset that ever moved through the vault in either direction. This is
 *     what catches L2-native tokens that were only ever *withdrawn* to L1
 *     (they have an NTV entry and an L1 representation but never appear in
 *     any deposit event).
 *   - Bridgehub.getAllZKChainChainIDs() × baseTokenAssetId(chainId) — base
 *     tokens of registered chains. Base-token bridging goes through
 *     `requestL2Transaction`, not the deposit paths above, so chains whose
 *     base token was bridged pre-v31 (e.g. custom-base-token chains) are
 *     invisible to the event scans.
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
const V31_UPGRADE_DIR = path.join(__dirname, "../upgrade-envs/v0.31.0-interopB");

/** Conservative default — covers most public RPCs without log-size pushback. */
const DEFAULT_BLOCK_STEP = 10_000;

// Minimal inline ABIs only for the bridgehub getter we need before any
// foundry-output ABI is loaded. Once we have the bridgehub we read the
// fuller ABIs from foundry-output JSON.
const BRIDGEHUB_GETTER_ABI = [
  "function assetRouter() view returns (address)",
  "function getAllZKChainChainIDs() view returns (uint256[])",
  "function baseTokenAssetId(uint256 chainId) view returns (bytes32)",
];
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
// IAssetHandler events emitted by the NTV on every finalized transfer in
// either direction. Signatures must match
// `contracts/bridge/interfaces/IAssetHandler.sol`.
const NTV_EVENTS_ABI = [
  "event BridgeMint(uint256 indexed chainId, bytes32 indexed assetId, address receiver, uint256 amount)",
  "event BridgeBurn(uint256 indexed chainId, bytes32 indexed assetId, address indexed sender, address receiver, uint256 amount)",
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
    ntvTransferLogs: number;
    ntvAssetIdsResolved: number;
    ntvAssetIdsSkipped: number;
    baseTokensResolved: number;
    baseTokensSkipped: number;
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
  const ntvIface = new ethers.utils.Interface(NTV_EVENTS_ABI);
  const ntv = new ethers.Contract(resolved.nativeTokenVault, NTV_TOKEN_ADDRESS_ABI, provider);
  const bh = new ethers.Contract(resolved.bridgehub, BRIDGEHUB_GETTER_ABI, provider);

  const tokens = new Set<string>();
  const counts = {
    legacyDepositInitiated: 0,
    bridgehubDepositInitiated: 0,
    erc20BridgeDepositInitiated: 0,
    assetIdsResolved: 0,
    assetIdsSkippedNonL1Native: 0,
    ntvTransferLogs: 0,
    ntvAssetIdsResolved: 0,
    ntvAssetIdsSkipped: 0,
    baseTokensResolved: 0,
    baseTokensSkipped: 0,
  };

  // `tokenAddress(assetId)` is queried by three passes below; cache the
  // answers so repeat assetIds cost one RPC call total.
  const tokenAddressCache = new Map<string, string>();
  async function resolveTokenAddress(assetId: string): Promise<string> {
    let addr = tokenAddressCache.get(assetId);
    if (addr === undefined) {
      addr = (await ntv.tokenAddress(assetId)) as string;
      tokenAddressCache.set(assetId, addr);
    }
    return addr;
  }

  // ── 1. AssetRouter.LegacyDepositInitiated ────────────────────────────
  const legacyDepositTopic = arIface.getEventTopic("LegacyDepositInitiated");
  console.log("\n[1/5] AssetRouter.LegacyDepositInitiated...");
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
  console.log("\n[2/5] AssetRouter.BridgehubDepositInitiated...");
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
    // `tokenAddress(assetId)` returns address(0) when the asset has no L1
    // representation (an L2-origin token that has never been withdrawn to
    // L1). Those have no NTV entry to migrate, so there is nothing to put in
    // the stage3 list; L2-origin tokens that DO have an L1 representation
    // are caught by the NTV BridgeMint/BridgeBurn pass below.
    const tokenAddress = await resolveTokenAddress(assetId);
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
  console.log("\n[3/5] L1ERC20Bridge.DepositInitiated...");
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

  // ── 4. NTV BridgeMint/BridgeBurn — every asset that ever moved through
  // the vault. Deposit-only scans miss L2-native tokens whose only L1
  // activity was a withdrawal (BridgeMint on L1); those still have an NTV
  // entry and fail `AssetNotMigratedFromNTV` post-v31 if left out.
  console.log("\n[4/5] L1NativeTokenVault.BridgeMint/BridgeBurn...");
  const ntvAssetIds = new Set<string>();
  for (const eventName of ["BridgeMint", "BridgeBurn"] as const) {
    const logs = await getLogsPaginated({
      provider,
      fromBlock,
      toBlock,
      blockStep,
      address: resolved.nativeTokenVault,
      topics: [ntvIface.getEventTopic(eventName)],
    });
    counts.ntvTransferLogs += logs.length;
    for (const log of logs) {
      ntvAssetIds.add(ntvIface.parseLog(log).args.assetId);
    }
  }
  console.log(`  scanned: ${counts.ntvTransferLogs} logs, unique assetIds: ${ntvAssetIds.size}`);
  for (const assetId of ntvAssetIds) {
    const tokenAddress = await resolveTokenAddress(assetId);
    if (tokenAddress === ethers.constants.AddressZero) {
      counts.ntvAssetIdsSkipped += 1;
      continue;
    }
    tokens.add(ethers.utils.getAddress(tokenAddress));
    counts.ntvAssetIdsResolved += 1;
  }
  console.log(
    `  resolved: ${counts.ntvAssetIdsResolved} addresses, skipped ${counts.ntvAssetIdsSkipped} without L1 representation; unique tokens so far: ${tokens.size}`
  );

  // ── 5. Base tokens of all registered chains. Base-token bridging goes
  // through `requestL2Transaction`, so it emits none of the deposit events
  // above; a pre-v31 custom base token (bridged before the NTV emitted
  // BridgeMint/BridgeBurn for it) would otherwise be missed and brick the
  // chain's withdrawals with `AssetIdNotRegistered`.
  console.log("\n[5/5] Bridgehub base tokens...");
  const chainIds: ethers.BigNumber[] = await bh.getAllZKChainChainIDs();
  for (const chainId of chainIds) {
    const assetId: string = await bh.baseTokenAssetId(chainId);
    if (assetId === ethers.constants.HashZero) {
      counts.baseTokensSkipped += 1;
      continue;
    }
    const tokenAddress = await resolveTokenAddress(assetId);
    if (tokenAddress === ethers.constants.AddressZero) {
      // No NTV entry — the base token has never been bridged, so there is
      // no legacy NTV state to migrate. (ETH-based chains resolve to
      // address(1) instead and are dropped by the ETH filter below.)
      counts.baseTokensSkipped += 1;
      continue;
    }
    tokens.add(ethers.utils.getAddress(tokenAddress));
    counts.baseTokensResolved += 1;
  }
  console.log(
    `  chains: ${chainIds.length}, resolved: ${counts.baseTokensResolved} base tokens, skipped ${counts.baseTokensSkipped}; unique tokens so far: ${tokens.size}`
  );

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
    `#   NTV.BridgeMint/BridgeBurn:              ${result.counts.ntvTransferLogs} logs => ${result.counts.ntvAssetIdsResolved} resolved (${result.counts.ntvAssetIdsSkipped} without L1 representation skipped)`,
    `#   Bridgehub base tokens:                  ${result.counts.baseTokensResolved} resolved (${result.counts.baseTokensSkipped} skipped)`,
    `# Unique tokens with legacy NTV entries: ${result.tokens.length}`,
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
  return path.join(V31_UPGRADE_DIR, `${envName}-bridged-tokens.toml`);
}

async function main(): Promise<void> {
  const program = new Command();

  program
    .name("discover-legacy-bridged-tokens")
    .description("Discover all legacy NTV tokens (deposits, NTV transfers, base tokens) for the v31 stage3 TOML.");

  program
    .command("discover")
    .description("Scan deposit + NTV transfer events and chain base tokens; write the per-env bridged-tokens TOML.")
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

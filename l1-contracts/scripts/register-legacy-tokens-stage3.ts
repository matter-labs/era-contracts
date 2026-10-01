#!/usr/bin/env ts-node
/**
 * Register v31 legacy bridged tokens directly from `<env>-bridged-tokens.toml`.
 *
 * This is an idempotent alternative to the generic stage3 balance pre-scan:
 * it iterates ETH + the configured token list, ensures each token is present
 * in NTV's bridgedTokens list, then calls L1AssetTracker.registerLegacyToken
 * only when the asset is not already registered.
 *
 * It ends with a completeness check: every chain's base token must be
 * registered in the AssetTracker afterwards. Base tokens are bridged via
 * `requestL2Transaction*`, so a stale token list can miss them, and an
 * unregistered one fails all of that chain's deposits and withdrawals with
 * `AssetIdNotRegistered`. A real run exits non-zero listing them; `--dry-run`
 * only prints the base tokens the run would leave unregistered.
 *
 * Both registration calls are permissionless. If another sender registers a
 * token between this script's check and its transaction, gas estimation
 * reverts with `TokenAlreadyInBridgedTokensList` / `AssetAlreadyRegistered`;
 * the script logs that and continues. Any other error stops the run, and a
 * rerun resumes where it stopped.
 *
 * Prerequisite:
 *   Run `forge build` in l1-contracts/ so `out/**.json` ABI files exist.
 */

import * as fs from "fs";
import * as path from "path";
import * as toml from "toml";
import { Command } from "commander";
import { ethers } from "ethers";
import { getBridgehubAddress, loadAbiFromFoundryOutput } from "./upgrade-script-utils";

const V31_UPGRADE_DIR = path.join(__dirname, "../upgrade-envs/v0.31.0-interopB");
const ETH_TOKEN_ADDRESS = "0x0000000000000000000000000000000000000001";
const ZERO_BYTES32 = ethers.constants.HashZero;
/** How deep `findRevertData` looks; ethers v5 puts the payload three `error` levels down. */
const MAX_ERROR_NESTING_DEPTH = 8;

interface TokenFile {
  tokens?: {
    bridged_tokens?: string[];
  };
}

function defaultTokensPath(envName: string): string {
  return path.join(V31_UPGRADE_DIR, `${envName}-bridged-tokens.toml`);
}

function readConfiguredTokens(filePath: string): string[] {
  if (!fs.existsSync(filePath)) {
    throw new Error(`Token file not found: ${filePath}`);
  }

  const parsed = toml.parse(fs.readFileSync(filePath, "utf8")) as TokenFile;
  const bridgedTokens = parsed.tokens?.bridged_tokens ?? [];
  const uniqueTokens = new Map<string, string>();

  for (const token of [ETH_TOKEN_ADDRESS, ...bridgedTokens]) {
    const checksummed = ethers.utils.getAddress(token);
    uniqueTokens.set(checksummed.toLowerCase(), checksummed);
  }

  return Array.from(uniqueTokens.values()).sort((a, b) => a.toLowerCase().localeCompare(b.toLowerCase()));
}

function requirePrivateKey(cmdPrivateKey: string | undefined): string {
  const privateKey = cmdPrivateKey ?? process.env.PRIVATE_KEY;
  if (!privateKey) {
    throw new Error("Pass --private-key or set PRIVATE_KEY. Use --dry-run to inspect without a signer.");
  }
  return privateKey;
}

async function waitTx(label: string, tx: ethers.ContractTransaction, confirmations: number): Promise<void> {
  console.log(`    tx sent: ${tx.hash}`);
  const receipt = await tx.wait(confirmations);
  console.log(`    ${label} confirmed in block ${receipt.blockNumber} (gasUsed=${receipt.gasUsed.toString()})`);
}

/**
 * Returns the revert data of a failed gas estimation. ethers v5 nests the
 * node's JSON-RPC error a few levels deep (`err.error.error…`); as in ethers'
 * own lookup, the payload is the object whose `message` mentions a revert and
 * whose `data` is hex.
 */
function findRevertData(value: unknown, depth = 0): string | undefined {
  if (typeof value !== "object" || value === null || depth > MAX_ERROR_NESTING_DEPTH) {
    return undefined;
  }
  const { message, data } = value as { message?: unknown; data?: unknown };
  if (
    typeof message === "string" &&
    /revert/i.test(message) &&
    typeof data === "string" &&
    ethers.utils.isHexString(data)
  ) {
    return data;
  }
  for (const nested of Object.values(value)) {
    const found = findRevertData(nested, depth + 1);
    if (found !== undefined) {
      return found;
    }
  }
  return undefined;
}

/**
 * Sends one of the two permissionless registration calls. Another sender can
 * land the same registration between this script's state check and its
 * transaction; gas estimation then reverts with `alreadyDoneError`, which
 * leaves the asset in the state we want, so only that revert is tolerated.
 * Returns whether this script's transaction did the work. Anything else is
 * rethrown, and a rerun resumes where the run stopped.
 */
async function sendRegistration(
  label: string,
  send: () => Promise<ethers.ContractTransaction>,
  errorInterface: ethers.utils.Interface,
  alreadyDoneError: string,
  confirmations: number
): Promise<boolean> {
  let tx: ethers.ContractTransaction;
  try {
    tx = await send();
  } catch (err) {
    const revertData = findRevertData(err)?.toLowerCase();
    if (revertData === undefined || !revertData.startsWith(errorInterface.getSighash(alreadyDoneError))) {
      throw err;
    }
    console.log(`    ${label} reverted with ${alreadyDoneError}: done by another sender meanwhile, continuing`);
    return false;
  }
  await waitTx(label, tx, confirmations);
  return true;
}

async function main(): Promise<void> {
  const program = new Command();

  program
    .name("register-legacy-tokens-stage3")
    .description("Idempotently register v31 legacy tokens from an env bridged-tokens TOML.")
    .requiredOption("--env <name>", "Env name (matches upgrade-envs/permanent-values/<env>.toml)")
    .requiredOption("--rpc <url>", "L1 RPC URL")
    .option(
      "--tokens-file <path>",
      "Token TOML path (default: upgrade-envs/v0.31.0-interopB/<env>-bridged-tokens.toml)"
    )
    .option("--private-key <hex>", "EOA private key used to submit permissionless registration transactions")
    .option("--dry-run", "Print planned actions without sending transactions")
    .option("--confirmations <n>", "Number of confirmations to wait for each tx", (v) => parseInt(v, 10), 1);

  const opts = program.parse(process.argv).opts<{
    env: string;
    rpc: string;
    tokensFile?: string;
    privateKey?: string;
    dryRun?: boolean;
    confirmations: number;
  }>();

  if (opts.confirmations < 1) {
    throw new Error("--confirmations must be at least 1");
  }

  const provider = new ethers.providers.JsonRpcProvider(opts.rpc);
  const signer = opts.dryRun ? provider : new ethers.Wallet(requirePrivateKey(opts.privateKey), provider);
  const sender = ethers.Signer.isSigner(signer) ? await signer.getAddress() : "<dry-run>";

  const tokensFile = opts.tokensFile ?? defaultTokensPath(opts.env);
  const tokens = readConfiguredTokens(tokensFile);
  const bridgehubAddress = getBridgehubAddress(opts.env);

  const bridgehubAbi = loadAbiFromFoundryOutput("../out/IBridgehubBase.sol/IBridgehubBase.json");
  const assetRouterAbi = loadAbiFromFoundryOutput("../out/IL1AssetRouter.sol/IL1AssetRouter.json");
  const ntvAbi = loadAbiFromFoundryOutput("../out/L1NativeTokenVault.sol/L1NativeTokenVault.json");
  const ntvBaseAbi = loadAbiFromFoundryOutput("../out/NativeTokenVaultBase.sol/NativeTokenVaultBase.json");
  // The implementation's ABI rather than IL1AssetTracker's: it carries the
  // AssetAlreadyRegistered error that `sendRegistration` matches.
  const assetTrackerAbi = loadAbiFromFoundryOutput("../out/L1AssetTracker.sol/L1AssetTracker.json");
  const assetTrackerBaseAbi = loadAbiFromFoundryOutput("../out/IAssetTrackerBase.sol/IAssetTrackerBase.json");

  const bridgehub = new ethers.Contract(bridgehubAddress, bridgehubAbi, signer);
  const assetRouterAddress = await bridgehub.assetRouter();
  const assetRouter = new ethers.Contract(assetRouterAddress, assetRouterAbi, signer);
  const ntvAddress = await assetRouter.nativeTokenVault();
  const ntv = new ethers.Contract(ntvAddress, ntvAbi, signer);
  const ntvBase = new ethers.Contract(ntvAddress, ntvBaseAbi, signer);
  const assetTrackerAddress = await ntv.l1AssetTracker();
  const assetTracker = new ethers.Contract(assetTrackerAddress, assetTrackerAbi, signer);
  const assetTrackerBase = new ethers.Contract(assetTrackerAddress, assetTrackerBaseAbi, signer);

  if (assetTrackerAddress === ethers.constants.AddressZero) {
    throw new Error(`NativeTokenVault ${ntvAddress} has no l1AssetTracker set`);
  }

  console.log("Legacy token registration plan:");
  console.log(`  Env:          ${opts.env}`);
  console.log(`  RPC:          ${opts.rpc}`);
  console.log(`  Sender:       ${sender}`);
  console.log(`  Bridgehub:    ${bridgehubAddress}`);
  console.log(`  AssetRouter:  ${assetRouterAddress}`);
  console.log(`  NTV:          ${ntvAddress}`);
  console.log(`  AssetTracker: ${assetTrackerAddress}`);
  console.log(`  Token file:   ${tokensFile}`);
  console.log(`  Tokens:       ${tokens.length} (ETH sentinel included)`);
  console.log(`  Mode:         ${opts.dryRun ? "dry-run" : "send transactions"}`);

  let alreadyRegistered = 0;
  let addedToBridgedList = 0;
  let registered = 0;
  let skippedMissingAssetId = 0;
  let doneByOtherSender = 0;
  // Dry-run only: assets this run would register, for the base-token check.
  const plannedRegistrations = new Set<string>();

  for (let index = 0; index < tokens.length; ++index) {
    const token = tokens[index];
    console.log(`\n[${index + 1}/${tokens.length}] ${token}`);

    const assetId: string = await ntv.assetId(token);
    if (assetId === ZERO_BYTES32) {
      console.log("  skip: token has no assetId in NTV");
      ++skippedMissingAssetId;
      continue;
    }
    console.log(`  assetId: ${assetId}`);

    const listIndex = await ntvBase.tokenIndex(assetId);
    const firstBridgedToken = await ntv.bridgedTokens(0);
    const inBridgedTokens = !listIndex.isZero() || firstBridgedToken.toLowerCase() === assetId.toLowerCase();
    if (inBridgedTokens) {
      console.log("  NTV bridgedTokens: already present");
    } else if (opts.dryRun) {
      console.log("  NTV bridgedTokens: would add legacy token");
    } else {
      console.log("  NTV bridgedTokens: adding legacy token");
      const added = await sendRegistration(
        "addLegacyTokenToBridgedTokensList",
        () => ntvBase.addLegacyTokenToBridgedTokensList(token),
        ntvBase.interface,
        "TokenAlreadyInBridgedTokensList",
        opts.confirmations
      );
      if (added) {
        ++addedToBridgedList;
      } else {
        ++doneByOtherSender;
      }
    }

    const isRegistered = await assetTrackerBase.isAssetRegistered(assetId);
    if (isRegistered) {
      console.log("  AssetTracker: already registered, skipping");
      ++alreadyRegistered;
      continue;
    }

    if (opts.dryRun) {
      console.log("  AssetTracker: would call registerLegacyToken");
      plannedRegistrations.add(assetId);
      continue;
    }

    console.log("  AssetTracker: registering legacy token");
    const didRegister = await sendRegistration(
      "registerLegacyToken",
      () => assetTracker.registerLegacyToken(assetId),
      assetTracker.interface,
      "AssetAlreadyRegistered",
      opts.confirmations
    );
    if (didRegister) {
      ++registered;
    } else {
      ++doneByOtherSender;
    }
  }

  console.log("\nDone.");
  console.log(`  Already registered:       ${alreadyRegistered}`);
  console.log(`  Added to NTV bridged list: ${addedToBridgedList}`);
  console.log(`  Registered in AT:         ${registered}`);
  console.log(`  Missing NTV assetId:      ${skippedMissingAssetId}`);
  console.log(`  Done by another sender:   ${doneByOtherSender}`);

  const chainIds: ethers.BigNumber[] = await bridgehub.getAllZKChainChainIDs();
  console.log(`\nBase-token check (${chainIds.length} chains):`);
  const unregisteredBaseTokens: string[] = [];
  for (const chainId of chainIds) {
    const baseTokenAssetId: string = await bridgehub.baseTokenAssetId(chainId);
    if (plannedRegistrations.has(baseTokenAssetId) || (await assetTrackerBase.isAssetRegistered(baseTokenAssetId))) {
      continue;
    }
    const baseToken: string = await ntv.tokenAddress(baseTokenAssetId);
    unregisteredBaseTokens.push(`chain ${chainId.toString()}: ${baseToken} (assetId ${baseTokenAssetId})`);
  }
  if (unregisteredBaseTokens.length === 0) {
    console.log(`  every base token is registered${opts.dryRun ? " or would be by this run" : ""}`);
  } else if (opts.dryRun) {
    console.log(`  this run would leave base tokens unregistered: ${unregisteredBaseTokens.join("; ")}`);
  } else {
    throw new Error(
      `Base tokens not registered in AssetTracker: ${unregisteredBaseTokens.join("; ")}. Add them to ${tokensFile} and rerun.`
    );
  }
}

main().catch((err) => {
  console.error(err instanceof Error ? (err.stack ?? err.message) : err);
  process.exit(1);
});

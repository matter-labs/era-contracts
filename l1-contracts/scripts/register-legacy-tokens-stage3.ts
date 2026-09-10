#!/usr/bin/env ts-node
/**
 * Register v31 legacy bridged tokens directly from `<env>-bridged-tokens.toml`.
 *
 * This is an idempotent alternative to the generic stage3 balance pre-scan:
 * it iterates ETH + the configured token list, ensures each token is present
 * in NTV's bridgedTokens list, then calls L1AssetTracker.registerLegacyToken
 * only when the asset is not already registered.
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
  const assetTrackerAbi = loadAbiFromFoundryOutput("../out/IL1AssetTracker.sol/IL1AssetTracker.json");
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
      const tx = await ntvBase.addLegacyTokenToBridgedTokensList(token);
      await waitTx("addLegacyTokenToBridgedTokensList", tx, opts.confirmations);
      ++addedToBridgedList;
    }

    const isRegistered = await assetTrackerBase.isAssetRegistered(assetId);
    if (isRegistered) {
      console.log("  AssetTracker: already registered, skipping");
      ++alreadyRegistered;
      continue;
    }

    if (opts.dryRun) {
      console.log("  AssetTracker: would call registerLegacyToken");
      continue;
    }

    console.log("  AssetTracker: registering legacy token");
    const tx = await assetTracker.registerLegacyToken(assetId);
    await waitTx("registerLegacyToken", tx, opts.confirmations);
    ++registered;
  }

  console.log("\nDone.");
  console.log(`  Already registered:       ${alreadyRegistered}`);
  console.log(`  Added to NTV bridged list: ${addedToBridgedList}`);
  console.log(`  Registered in AT:         ${registered}`);
  console.log(`  Missing NTV assetId:      ${skippedMissingAssetId}`);
}

main().catch((err) => {
  console.error(err instanceof Error ? (err.stack ?? err.message) : err);
  process.exit(1);
});

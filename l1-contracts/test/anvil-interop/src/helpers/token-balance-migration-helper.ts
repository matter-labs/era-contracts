import { Contract, ethers, providers, Wallet } from "ethers";
import { getAbi } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  DEFAULT_TX_GAS_LIMIT,
  GW_ASSET_TRACKER_ADDR,
  L1_MESSAGE_SENT_EVENT_SIG,
  L2_ASSET_TRACKER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../core/const";
import {
  assertContractDeployed,
  buildFinalizeWithdrawalParams,
  extractAndRelayNewPriorityRequests,
} from "../core/utils";
import { encodeNtvAssetId } from "../core/data-encoding";
import type { ChainAddresses } from "../core/types";
import { getInteropSourcePrivateKey } from "../core/accounts";
import { waitForLiveFinalizeWithdrawalParams } from "./temp-sdk";

const TBM_L1_RECEIVE_GAS_LIMIT = 10_000_000;
const TBM_REGISTER_TOKEN_GAS_LIMIT = 500_000;
const DEFAULT_TBM_TIMEOUT_MS = 10 * 60 * 1000;
const DEFAULT_TBM_POLL_MS = 5_000;

type Logger = (line: string) => void;

export interface MigrateSpecificTokenBalanceToGWParams {
  l2RpcUrl: string;
  l1RpcUrl: string;
  /** Optional gateway RPC. When provided, the helper waits for GW and L2 migration confirmations. */
  gwRpcUrl?: string;
  chainId: number;
  /** Token address on the source L2 chain. Required unless assetId is supplied. */
  tokenAddress?: string;
  /** Asset ID to migrate. If omitted, it is read from L2NativeTokenVault after registering tokenAddress. */
  assetId?: string;
  /** L1NativeTokenVault address. Used to discover L1AssetTracker when l1AssetTrackerAddr is omitted. */
  l1NativeTokenVaultAddr: string;
  /** Optional explicit L1AssetTracker address. */
  l1AssetTrackerAddr?: string;
  privateKey?: string;
  timeoutMs?: number;
  pollMs?: number;
  logger?: Logger;
}

export interface TokenBalanceMigrationResult {
  assetId: string;
  l2TxHash?: string;
  l1TxHash?: string;
  alreadyMigrated: boolean;
}

/**
 * Orchestrates the full Token Balance Migration (TBM) flow:
 *
 * 1. L2: Call L2AssetTracker.initiateL1ToGatewayMigrationOnL2(assetId) — emits L2→L1 message
 * 2. L1: Call L1AssetTracker.receiveL1ToGatewayMigrationOnL1(params) — processes migration,
 *    sends two L1→chain service txs:
 *    a. confirmMigrationOnGateway → GW (via GW diamond proxy)
 *    b. confirmMigrationOnL2 → L2 chain (via L2 chain's diamond proxy)
 * 3. Extract NewPriorityRequest events from the L1 receipt and relay them to the target chains.
 *    Destination addresses are extracted from the event data itself.
 */
export async function migrateTokenBalanceToGW(params: {
  l2Provider: providers.JsonRpcProvider;
  l1Provider: providers.JsonRpcProvider;
  gwProvider: providers.JsonRpcProvider;
  chainId: number;
  assetId: string;
  l1AssetTrackerAddr: string;
  gwDiamondProxyAddr: string;
  l2DiamondProxyAddr: string;
  logger?: (line: string) => void;
}): Promise<void> {
  const log = params.logger || console.log;
  const {
    l2Provider,
    l1Provider,
    gwProvider,
    chainId,
    assetId,
    l1AssetTrackerAddr,
    gwDiamondProxyAddr,
    l2DiamondProxyAddr,
  } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  // ── Step 1: Call initiateL1ToGatewayMigrationOnL2 on L2 ──

  log(`   [TBM] Step 1: Calling initiateL1ToGatewayMigrationOnL2 on chain ${chainId}...`);

  const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), l2Provider);
  const l2Wallet = new ethers.Wallet(privateKey, l2Provider);

  const l2Tx = await l2AssetTracker.connect(l2Wallet).initiateL1ToGatewayMigrationOnL2(assetId, {
    gasLimit: 5_000_000,
  });
  const l2Receipt = await l2Tx.wait();

  // Check if the migration was already completed (no L1MessageSent event emitted).
  // The L2 contract returns early when assetMigrationNumber == chainMigrationNumber.
  const l1MessageSentTopic = ethers.utils.id(L1_MESSAGE_SENT_EVENT_SIG);
  const hasL1Message = l2Receipt.logs.some((l: { topics: string[] }) => l.topics[0] === l1MessageSentTopic);
  if (!hasL1Message) {
    log(`   [TBM] Migration already completed for asset ${assetId} on chain ${chainId}, skipping L1 steps`);
    return;
  }

  // ── Step 2: Build finalization params and call receiveL1ToGatewayMigrationOnL1 on L1 ──

  log("   [TBM] Step 2: Calling receiveL1ToGatewayMigrationOnL1 on L1...");

  const finalizeParams = buildFinalizeWithdrawalParams(l2Receipt, chainId);
  log(`   [TBM] Captured L2→L1 message (${finalizeParams.message.length} chars)`);

  const l1AssetTracker = new Contract(l1AssetTrackerAddr, getAbi("L1AssetTracker"), l1Provider);
  const l1Wallet = new ethers.Wallet(privateKey, l1Provider);

  const l1Tx = await l1AssetTracker.connect(l1Wallet).receiveL1ToGatewayMigrationOnL1(finalizeParams, {
    gasLimit: 10_000_000,
  });
  const l1Receipt = await l1Tx.wait();
  log(`   [TBM] L1 tx: cast run ${l1Receipt.transactionHash} -r ${l1Provider.connection.url}`);

  // ── Step 3: Extract and relay all NewPriorityRequest events to target chains ──

  log("   [TBM] Step 3: Extracting and relaying NewPriorityRequest events...");

  const txHashes = await extractAndRelayNewPriorityRequests(
    l1Receipt,
    [
      { diamondProxy: gwDiamondProxyAddr, provider: gwProvider },
      { diamondProxy: l2DiamondProxyAddr, provider: l2Provider },
    ],
    log
  );

  if (txHashes.length === 0) {
    throw new Error(
      "No NewPriorityRequest events found in L1 receipt. " + `TX: ${l1Receipt.transactionHash}, chain: ${chainId}`
    );
  }

  log(`   [TBM] Token balance migration complete for chain ${chainId}, assetId ${assetId}`);
}

/**
 * Run the real Token Balance Migration flow for one token on one GW-settled chain.
 *
 * This mirrors the integration-test flow without zksync-ethers:
 * 1. Register the token in L2NativeTokenVault when needed.
 * 2. Call L2AssetTracker.initiateL1ToGatewayMigrationOnL2(assetId).
 * 3. Build the real L2->L1 message inclusion params through ZKsync RPC.
 * 4. Call L1AssetTracker.receiveL1ToGatewayMigrationOnL1(params).
 * 5. Optionally wait until Gateway and L2 confirmation service txs mark the token migrated.
 */
export async function migrateSpecificTokenBalanceToGW(
  params: MigrateSpecificTokenBalanceToGWParams
): Promise<TokenBalanceMigrationResult> {
  const log = params.logger || console.log;
  const timeoutMs = params.timeoutMs ?? DEFAULT_TBM_TIMEOUT_MS;
  const privateKey = params.privateKey || getInteropSourcePrivateKey();
  const l2Provider = new providers.JsonRpcProvider(params.l2RpcUrl);
  const l1Provider = new providers.JsonRpcProvider(params.l1RpcUrl);
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const l1Wallet = new Wallet(privateKey, l1Provider);
  const assetId = await resolveSpecificTokenAssetId({
    l2Provider,
    l2Wallet,
    chainId: params.chainId,
    tokenAddress: params.tokenAddress,
    assetId: params.assetId,
    logger: log,
  });

  const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), l2Wallet);
  if (await l2AssetTracker.tokenMigrated(params.chainId, assetId)) {
    log(`   [TBM] Token ${assetId} is already migrated on chain ${params.chainId}`);
    return { assetId, alreadyMigrated: true };
  }

  log(`   [TBM] Initiating migration for ${assetId} on chain ${params.chainId}...`);
  const l2Tx = await l2AssetTracker.initiateL1ToGatewayMigrationOnL2(assetId, {
    gasLimit: DEFAULT_TX_GAS_LIMIT,
  });
  const l2Receipt = await l2Tx.wait();

  const l1MessageSentTopic = ethers.utils.id(L1_MESSAGE_SENT_EVENT_SIG);
  const hasL1Message = l2Receipt.logs.some(
    (logEntry: { topics: string[] }) => logEntry.topics[0] === l1MessageSentTopic
  );
  if (!hasL1Message) {
    log(`   [TBM] Migration already completed for asset ${assetId} on chain ${params.chainId}`);
    return { assetId, l2TxHash: l2Receipt.transactionHash, alreadyMigrated: true };
  }

  const l1AssetTrackerAddr =
    params.l1AssetTrackerAddr || (await discoverL1AssetTracker(l1Provider, params.l1NativeTokenVaultAddr));
  const l1AssetTracker = new Contract(l1AssetTrackerAddr, getAbi("L1AssetTracker"), l1Wallet);

  log("   [TBM] Building L2->L1 migration proof params...");
  const finalizeParams = await waitForLiveFinalizeWithdrawalParams(
    l2Provider,
    l2Receipt.transactionHash,
    params.chainId,
    0,
    timeoutMs
  );

  log("   [TBM] Calling receiveL1ToGatewayMigrationOnL1 on L1...");
  const l1Tx = await l1AssetTracker.receiveL1ToGatewayMigrationOnL1(finalizeParams, {
    gasLimit: TBM_L1_RECEIVE_GAS_LIMIT,
  });
  const l1Receipt = await l1Tx.wait();
  log(`   [TBM] L1 tx: cast run ${l1Receipt.transactionHash} -r ${params.l1RpcUrl}`);

  if (params.gwRpcUrl) {
    const gwProvider = new providers.JsonRpcProvider(params.gwRpcUrl);
    await waitForTokenMigrated({
      provider: gwProvider,
      trackerAddress: GW_ASSET_TRACKER_ADDR,
      trackerName: "GWAssetTracker",
      trackerContract: "GWAssetTracker",
      chainId: params.chainId,
      assetId,
      timeoutMs,
      pollMs: params.pollMs,
      logger: log,
    });
    await waitForTokenMigrated({
      provider: l2Provider,
      trackerAddress: L2_ASSET_TRACKER_ADDR,
      trackerName: "L2AssetTracker",
      trackerContract: "L2AssetTracker",
      chainId: params.chainId,
      assetId,
      timeoutMs,
      pollMs: params.pollMs,
      logger: log,
    });
  }

  log(`   [TBM] Token balance migration complete for chain ${params.chainId}, assetId ${assetId}`);
  return {
    assetId,
    l2TxHash: l2Receipt.transactionHash,
    l1TxHash: l1Receipt.transactionHash,
    alreadyMigrated: false,
  };
}

async function resolveSpecificTokenAssetId(params: {
  l2Provider: providers.JsonRpcProvider;
  l2Wallet: Wallet;
  chainId: number;
  tokenAddress?: string;
  assetId?: string;
  logger: Logger;
}): Promise<string> {
  if (!params.tokenAddress) {
    if (!params.assetId) {
      throw new Error("tokenAddress or assetId is required for token balance migration");
    }
    return params.assetId;
  }

  await assertContractDeployed(params.l2Provider, params.tokenAddress, `Token ${params.tokenAddress}`);
  const ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), params.l2Wallet);
  let assetId: string = await ntv.assetId(params.tokenAddress);
  if (assetId === ethers.constants.HashZero) {
    params.logger(`   [TBM] Registering token ${params.tokenAddress} on L2NativeTokenVault...`);
    const registerTx = await ntv.registerToken(params.tokenAddress, { gasLimit: TBM_REGISTER_TOKEN_GAS_LIMIT });
    await registerTx.wait();
    assetId = await ntv.assetId(params.tokenAddress);
  }

  if (assetId === ethers.constants.HashZero) {
    throw new Error(`Token ${params.tokenAddress} did not resolve to an asset ID after registration`);
  }
  if (params.assetId && params.assetId !== assetId) {
    throw new Error(
      `Provided asset ID ${params.assetId} does not match token ${params.tokenAddress} asset ID ${assetId}`
    );
  }
  return assetId;
}

async function discoverL1AssetTracker(
  l1Provider: providers.JsonRpcProvider,
  l1NativeTokenVaultAddr: string
): Promise<string> {
  const l1NativeTokenVault = new Contract(l1NativeTokenVaultAddr, getAbi("L1NativeTokenVault"), l1Provider);
  const l1AssetTrackerAddr = await l1NativeTokenVault.l1AssetTracker();
  if (l1AssetTrackerAddr === ethers.constants.AddressZero) {
    throw new Error("L1NativeTokenVault.l1AssetTracker() returned zero address");
  }
  return l1AssetTrackerAddr;
}

async function waitForTokenMigrated(params: {
  provider: providers.JsonRpcProvider;
  trackerAddress: string;
  trackerName: string;
  trackerContract: "GWAssetTracker" | "L2AssetTracker";
  chainId: number;
  assetId: string;
  timeoutMs: number;
  pollMs?: number;
  logger: Logger;
}): Promise<void> {
  const tracker = new Contract(params.trackerAddress, getAbi(params.trackerContract), params.provider);
  const startedAt = Date.now();
  const pollMs = params.pollMs ?? params.provider.pollingInterval ?? DEFAULT_TBM_POLL_MS;

  while (!(await tracker.tokenMigrated(params.chainId, params.assetId))) {
    if (Date.now() - startedAt > params.timeoutMs) {
      throw new Error(
        `${params.trackerName}.tokenMigrated(${params.chainId}, ${params.assetId}) did not become true within ${params.timeoutMs}ms`
      );
    }
    await sleep(pollMs);
  }

  params.logger(`   [TBM] ${params.trackerName} confirms token migrated`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

/**
 * Register a test token on L2NativeTokenVault if not already registered.
 */
export async function registerTestTokenOnL2NTV(
  l2Provider: providers.JsonRpcProvider,
  tokenAddr: string,
  chainId: number,
  logger?: (line: string) => void
): Promise<void> {
  const log = logger || console.log;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;
  const l2Wallet = new Wallet(privateKey, l2Provider);
  const ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), l2Wallet);

  const existingAssetId = await ntv.assetId(tokenAddr);
  if (existingAssetId === ethers.constants.HashZero) {
    await assertContractDeployed(l2Provider, tokenAddr, `Test token on chain ${chainId}`);
    const regTx = await ntv.registerToken(tokenAddr, { gasLimit: 500_000 });
    await regTx.wait();
    log(`   Registered test token ${tokenAddr} on L2NTV (chain ${chainId})`);
  }
}

/**
 * Run Token Balance Migration (TBM) for test tokens on all GW-settled chains.
 *
 * For each GW-settled chain that has a test token:
 * 1. Register the token on L2NativeTokenVault if needed
 * 2. Run the full TBM flow (L2 → L1 → GW+L2 confirmations)
 *
 * This properly sets assetMigrationNumber on both the GW and L2 chains,
 * which is required for outgoing transfers from GW-settled chains.
 */
export async function registerAndMigrateTestTokens(params: {
  gwSettledChainIds: number[];
  l2ChainRpcUrls: Map<number, string>;
  testTokens: Record<number, string>;
  l1RpcUrl: string;
  gwRpcUrl: string;
  l1AssetTrackerAddr: string;
  gwDiamondProxyAddr: string;
  chainAddresses: ChainAddresses[];
  logger?: (line: string) => void;
}): Promise<void> {
  const log = params.logger || console.log;
  const {
    gwSettledChainIds,
    l2ChainRpcUrls,
    testTokens,
    l1RpcUrl,
    gwRpcUrl,
    l1AssetTrackerAddr,
    gwDiamondProxyAddr,
    chainAddresses,
  } = params;

  const l1Provider = new providers.JsonRpcProvider(l1RpcUrl);
  const gwProvider = new providers.JsonRpcProvider(gwRpcUrl);

  // Build chain configs, skipping chains without necessary data
  const chainConfigs = gwSettledChainIds
    .map((chainId) => {
      const rpcUrl = l2ChainRpcUrls.get(chainId);
      const l2DiamondProxy = chainAddresses.find((c) => c.chainId === chainId)?.diamondProxy;
      const tokenAddr = testTokens[chainId];
      if (!rpcUrl || !l2DiamondProxy || !tokenAddr) return null;
      return { chainId, rpcUrl, l2DiamondProxy, tokenAddr };
    })
    .filter((c): c is NonNullable<typeof c> => c !== null);

  // Phase 1: Register test tokens on L2NTV in parallel (different L2 chains)
  await Promise.all(
    chainConfigs.map(async ({ chainId, rpcUrl, tokenAddr }) => {
      const l2Provider = new providers.JsonRpcProvider(rpcUrl);
      await registerTestTokenOnL2NTV(l2Provider, tokenAddr, chainId, log);
    })
  );

  // Phase 2: TBM for each chain (sequential — L1 nonce + GW relay conflicts)
  for (const { chainId, rpcUrl, l2DiamondProxy, tokenAddr } of chainConfigs) {
    const l2Provider = new providers.JsonRpcProvider(rpcUrl);
    const assetId = encodeNtvAssetId(chainId, tokenAddr);
    await migrateTokenBalanceToGW({
      l2Provider,
      l1Provider,
      gwProvider,
      chainId,
      assetId,
      l1AssetTrackerAddr,
      gwDiamondProxyAddr,
      l2DiamondProxyAddr: l2DiamondProxy,
      logger: log,
    });
    log(`   TBM complete for test token on chain ${chainId}`);
  }
}

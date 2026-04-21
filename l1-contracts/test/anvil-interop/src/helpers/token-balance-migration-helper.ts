import { Contract, ethers, providers, Wallet } from "ethers";
import { getAbi } from "../core/contracts";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
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
  log(`   [TBM] L2 tx: cast run ${l2Receipt.transactionHash} -r ${l2Provider.connection.url}`);

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
 * Orchestrates the reverse Token Balance Migration (TBM) flow — from gateway back to L1.
 *
 * 1. GW: Call `GWAssetTracker.initiateGatewayToL1MigrationOnGateway(chainId, assetId)` —
 *    drains the GW `chainBalance[chainId][assetId]` and emits a GW→L1 message.
 * 2. L1: Build finalisation params from the GW receipt and call
 *    `L1AssetTracker.receiveGatewayToL1MigrationOnL1(params)` — restores the L1
 *    `chainBalance[chainId][assetId]` and sends confirmation priority txs to GW and L2.
 * 3. Relay the L1 `NewPriorityRequest` events to GW and the migrating L2 chain so both
 *    sides apply the confirmation transactions.
 *
 * Preconditions:
 * - Chain's settlement layer must have been changed back to L1 (chain `migrationNumber`
 *   incremented on both the L2 `L2ChainAssetHandler` and the GW `L2ChainAssetHandler`).
 *   Use `setSettlementLayerViaBootloader` for the L2 side and
 *   `simulateGWChainMigrationBurn` for the GW side.
 * - The asset must have been previously migrated to GW (L1 `assetMigrationNumber` is
 *   below the chain's current `migrationNumber`).
 */
export async function migrateTokenBalanceFromGW(params: {
  gwProvider: providers.JsonRpcProvider;
  l1Provider: providers.JsonRpcProvider;
  l2Provider: providers.JsonRpcProvider;
  chainId: number;
  assetId: string;
  l1AssetTrackerAddr: string;
  gwChainId: number;
  gwDiamondProxyAddr: string;
  l2DiamondProxyAddr: string;
  logger?: (line: string) => void;
}): Promise<void> {
  const log = params.logger || console.log;
  const {
    gwProvider,
    l1Provider,
    l2Provider,
    chainId,
    assetId,
    l1AssetTrackerAddr,
    gwChainId,
    gwDiamondProxyAddr,
    l2DiamondProxyAddr,
  } = params;
  const privateKey = ANVIL_DEFAULT_PRIVATE_KEY;

  // ── Step 1: Call initiateGatewayToL1MigrationOnGateway on GW ──

  log(`   [TBM-reverse] Step 1: Calling initiateGatewayToL1MigrationOnGateway for chain ${chainId}...`);

  const gwAssetTracker = new Contract(GW_ASSET_TRACKER_ADDR, getAbi("GWAssetTracker"), gwProvider);
  const gwWallet = new ethers.Wallet(privateKey, gwProvider);

  const gwTx = await gwAssetTracker.connect(gwWallet).initiateGatewayToL1MigrationOnGateway(chainId, assetId, {
    gasLimit: 5_000_000,
  });
  const gwReceipt = await gwTx.wait();
  log(`   [TBM-reverse] GW tx: cast run ${gwReceipt.transactionHash} -r ${gwProvider.connection.url}`);

  // ── Step 2: Build finalisation params and call receiveGatewayToL1MigrationOnL1 on L1 ──

  log("   [TBM-reverse] Step 2: Calling receiveGatewayToL1MigrationOnL1 on L1...");

  const finalizeParams = buildFinalizeWithdrawalParams(gwReceipt, gwChainId);
  log(`   [TBM-reverse] Captured GW→L1 message (${finalizeParams.message.length} chars)`);

  const l1AssetTracker = new Contract(l1AssetTrackerAddr, getAbi("L1AssetTracker"), l1Provider);
  const l1Wallet = new ethers.Wallet(privateKey, l1Provider);

  const l1Tx = await l1AssetTracker.connect(l1Wallet).receiveGatewayToL1MigrationOnL1(finalizeParams, {
    gasLimit: 10_000_000,
  });
  const l1Receipt = await l1Tx.wait();
  log(`   [TBM-reverse] L1 tx: cast run ${l1Receipt.transactionHash} -r ${l1Provider.connection.url}`);

  // ── Step 3: Relay NewPriorityRequest events to GW and L2 ──

  log("   [TBM-reverse] Step 3: Relaying NewPriorityRequest events...");

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

  log(`   [TBM-reverse] Reverse token balance migration complete for chain ${chainId}, assetId ${assetId}`);
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

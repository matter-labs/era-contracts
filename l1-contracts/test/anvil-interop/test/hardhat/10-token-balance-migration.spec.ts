/**
 * 10 - Token Balance Migration Lifecycle
 *
 * Exercises the end-to-end Token Balance Migration (TBM) flow across L1, GW and an
 * L2 chain, with negative-path checks at each stage and conservation invariants.
 *
 * Covered stages:
 *
 *   - Pre-migration state on the L1-settled chain (interop sending is rejected
 *     until the chain is migrated to GW).
 *   - Forward TBM (L1 → GW) for ETH and an NTV test token, verifying that the L1
 *     and GW sides agree on `assetMigrationNumber` and that the GW per-chain
 *     `chainBalance` is bounded by the L1 `chainBalance[GW][ETH]`.
 *   - Reverse TBM (GW → L1):
 *       - `setSettlementLayerViaBootloader` on the L2 side (real SystemContext path),
 *       - `simulateGWChainMigrationBurn` on the GW side, which reproduces the two
 *         observable effects of production `bridgeBurn` via the real Solidity entry
 *         points (see `harness-shims.ts` for the full rationale),
 *       - `GWAssetTracker.initiateGatewayToL1MigrationOnGateway` drives the real
 *         reverse-TBM entry point on GW (`chainBalance` drained, GW
 *         `assetMigrationNumber` advanced to 2),
 *       - `installL1ChainAssetHandlerDev` + `setL1ChainMigrationNumber` bump the
 *         L1 `ChainAssetHandler.migrationNumber[chainId]` to 2 — matching the
 *         observable effect of the chain-level migrate-from-gateway `bridgeMint`
 *         the zksync-era source test covers via a real sequencer/prover pipeline
 *         that the Anvil harness cannot instantiate (priority-tree + batch
 *         invariants on `Migrator.forwardedBridgeBurn`),
 *       - `receiveGatewayToL1MigrationOnL1` then runs against the real L1
 *         contract path, finalises the reverse TBM on L1, and emits
 *         confirmation priority txs that are relayed to GW and L2 so that
 *         `assetMigrationNumber` reaches 2 on all three sides.
 *
 *     Replay protection is asserted on GW with the exact
 *     `InvalidAssetMigrationNumber` selector.
 *
 * Chain topology (see `config/anvil-config.json`):
 *
 *   Chain 10  — settling on L1, `migrationNumber = 0`.
 *   Chain 11  — GW.
 *   Chain 12  — GW-settled, `migrationNumber = 1` after gateway setup.
 *   Chain 13  — GW-settled, `migrationNumber = 1`.
 *   Chain 14  — GW-settled, custom ERC20 base token (added in #2108).
 */

import { expect } from "chai";
import { BigNumber, Contract, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import {
  buildFinalizeWithdrawalParams,
  buildMockInteropProof,
  extractNewPriorityRequests,
  getChainDiamondProxy,
  getChainIdByRole,
  getChainIdsByRole,
  getL1RpcUrl,
  getL2RpcUrl,
  impersonateAndRun,
  relayTx,
} from "../../src/core/utils";
import { getAbi, getCreationBytecode } from "../../src/core/contracts";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import {
  ANVIL_DEFAULT_PRIVATE_KEY,
  ETH_TOKEN_ADDRESS,
  GW_ASSET_TRACKER_ADDR,
  INTEROP_CENTER_ADDR,
  L1_CHAIN_ID,
  L2_ASSET_TRACKER_ADDR,
  L2_BRIDGEHUB_ADDR,
  L2_CHAIN_ASSET_HANDLER_ADDR,
  L2_INTEROP_HANDLER_ADDR,
  L2_NATIVE_TOKEN_VAULT_ADDR,
} from "../../src/core/const";
import {
  migrateTokenBalanceToGW,
  queryAssetMigrationNumber,
  queryL1ChainBalance,
} from "../../src/helpers/token-balance-migration-helper";
import { depositETHToL2, depositERC20ToL2 } from "../../src/helpers/l1-deposit-helper";
import type { PendingWithdrawal } from "../../src/helpers/l2-withdrawal-helper";
import {
  finalizeWithdrawalOnL1,
  initiateErc20Withdrawal,
  initiateEthWithdrawal,
} from "../../src/helpers/l2-withdrawal-helper";
import {
  completeL1ChainMigrationSettlementLayer,
  installL1ChainAssetHandlerDev,
  installL2ChainAssetHandlerDev,
  setL1ChainMigrationNumber,
  setSettlementLayerViaBootloader,
  simulateGWChainMigrationBurn,
} from "../../src/helpers/harness-shims";
import { getGWChainBalance } from "../../src/helpers/process-logs-helper";
import { customError, expectRevert, randomBigNumber } from "../../src/helpers/balance-helpers";
import { encodeEvmChain } from "../../src/helpers/erc7930";

// A chain ID that is intentionally not registered in the anvil-interop topology.
// Used to exercise the `DestinationChainNotRegistered` reject path.
const UNREGISTERED_CHAIN_ID = 1337;
// Chain ID encoded as an ERC-7930 destination value, minus any address payload
// (the chain-less form is what InteropCenter.sendBundle expects).
const UNREGISTERED_DESTINATION_BYTES = encodeEvmChain(UNREGISTERED_CHAIN_ID);

const POST_REVERSE_MIGRATION_NUMBER = 2;

// Random-amount ranges scoped to the specific flow that consumes them. Ranges are
// kept small relative to Anvil's default account balance so a fresh deploy and a
// pregenerated-state run both have headroom for deposits, TBM, and assertions.
const TBM_DEPOSIT_AMOUNT_RANGE = {
  min: ethers.utils.parseEther("0.25"),
  max: ethers.utils.parseEther("0.75"),
};
const TBM_WITHDRAWAL_AMOUNT_RANGE = {
  min: BigNumber.from(1),
  max: BigNumber.from(1_000),
};
const INTEROP_SMOKE_BUNDLE_VALUE_RANGE = {
  min: BigNumber.from(1),
  max: BigNumber.from(1_000_000),
};

describe("10 - Token Balance Migration Lifecycle", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  // Chain topology
  let gwChainId: number;
  let gwSettledChainIds: number[];
  let l1SettledChainId: number;
  // The GW-settled chain that is the subject of the reverse-TBM flow.
  let reverseTbmChainId: number;

  // Providers
  let l1Provider: ethers.providers.JsonRpcProvider;
  let gwProvider: ethers.providers.JsonRpcProvider;
  let l1SettledProvider: ethers.providers.JsonRpcProvider;
  let reverseTbmProvider: ethers.providers.JsonRpcProvider;

  // Addresses
  let bridgehubAddr: string;
  let l1AssetTrackerAddr: string;
  let l1ChainAssetHandlerProxy: string;
  let gwDiamondProxy: string;
  let reverseTbmDiamondProxy: string;

  // Asset IDs
  let ethAssetId: string;
  let reverseTbmTestTokenAssetId: string;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses || !state.testTokens) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }

    gwChainId = getChainIdByRole(state.chains.config, "gateway");
    gwSettledChainIds = getChainIdsByRole(state.chains.config, "gwSettled");
    l1SettledChainId = getChainIdByRole(state.chains.config, "directSettled");
    reverseTbmChainId = gwSettledChainIds[0];

    l1Provider = new ethers.providers.JsonRpcProvider(getL1RpcUrl(state));
    gwProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, gwChainId));
    l1SettledProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, l1SettledChainId));
    reverseTbmProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, reverseTbmChainId));

    bridgehubAddr = state.l1Addresses!.bridgehub;
    l1AssetTrackerAddr = state.l1Addresses!.l1AssetTracker;
    gwDiamondProxy = getChainDiamondProxy(state.chainAddresses!, gwChainId);
    reverseTbmDiamondProxy = getChainDiamondProxy(state.chainAddresses!, reverseTbmChainId);

    ethAssetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
    reverseTbmTestTokenAssetId = encodeNtvAssetId(reverseTbmChainId, state.testTokens![reverseTbmChainId]);

    // Install the dev variant of L2ChainAssetHandler on GW so the reverse-TBM setup
    // can drive `migrationNumber[chainId]` through `setMigrationNumberForTesting`
    // without fabricating a priority tree / batch-execution state. The dev variant
    // preserves the production storage layout and entry points — all non-test flows
    // behave identically. See harness-shims.installL2ChainAssetHandlerDev.
    await installL2ChainAssetHandlerDev(gwProvider);

    // Install the dev variant of L1ChainAssetHandler on L1 behind its
    // TransparentUpgradeableProxy. The install helper deploys a fresh Dev impl
    // (real constructor → production immutables) and then drives the upgrade
    // through the proxy's real admin surface (`ITransparentUpgradeableProxy.upgradeTo`,
    // impersonated from the EIP-1967 admin slot) — the same call shape
    // `ProxyAdmin.upgrade(proxy, newImpl)` reaches in production. Proxy storage
    // is untouched; only the dev setter becomes reachable to the `onlyOwner` caller.
    l1ChainAssetHandlerProxy = await installL1ChainAssetHandlerDev(l1Provider, bridgehubAddr);
  });

  // ── Pre-migration state on the L1-settled chain ─────────────────

  describe("Pre-migration state (L1-settled chain)", () => {
    it("L1AT assetMigrationNumber is 0 for an L1-settled chain (ETH)", async () => {
      const migNum = await queryAssetMigrationNumber(
        l1Provider,
        l1AssetTrackerAddr,
        "L1AssetTracker",
        l1SettledChainId,
        ethAssetId
      );
      expect(migNum, `L1AT assetMigrationNumber[${l1SettledChainId}][ETH]`).to.equal(0);
    });

    it("cannot send an interop bundle from an L1-settled chain (NotInGatewayMode)", async () => {
      const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1SettledProvider);
      const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);
      // Chain-less ERC-7930 encoding of a dummy destination — the function reverts
      // before decoding because the caller's settlement layer is L1. We use
      // `callStatic` rather than sending a tx so the custom-error selector is
      // exposed in the error data (Anvil does not surface it on tx receipts).
      const destinationBytes = "0x00010000010d00";

      await expectRevert(
        () => interopCenter.callStatic.sendBundle(destinationBytes, [], [], { gasLimit: 500_000, value: 0 }),
        "sendBundle from L1-settled chain",
        customError("InteropCenter", "NotInGatewayMode()"),
        l1SettledProvider
      );
    });

    it("cannot execute an interop bundle on an L1-settled chain (CannotClaimInteropOnL1Settlement)", async () => {
      const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1SettledProvider);
      const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);
      const dummyProof = buildMockInteropProof(gwSettledChainIds[0]);

      // `callStatic` surfaces the custom-error selector; plain Anvil tx receipts
      // strip revert data and only report "reverted".
      await expectRevert(
        () => interopHandler.callStatic.executeBundle("0x", dummyProof, { gasLimit: 500_000 }),
        "executeBundle on L1-settled chain",
        customError("InteropHandler", "CannotClaimInteropOnL1Settlement()"),
        l1SettledProvider
      );
    });

    it("cannot unbundle an interop bundle on an L1-settled chain (CannotClaimInteropOnL1Settlement)", async () => {
      const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1SettledProvider);
      const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);

      await expectRevert(
        () => interopHandler.callStatic.unbundleBundle("0x", [], { gasLimit: 500_000 }),
        "unbundleBundle on L1-settled chain",
        customError("InteropHandler", "CannotClaimInteropOnL1Settlement()"),
        l1SettledProvider
      );
    });
  });

  // ── Forward TBM (L1 → GW) ───────────────────────────────────────────

  describe("Forward TBM (L1 → GW)", () => {
    it("L1AT and GWAT assetMigrationNumber match and are >= 1 for ETH on every ETH-base GW-settled chain", async () => {
      // Custom-base-token chains (e.g. chain 14) do not migrate ETH, so we filter
      // by base token rather than over-matching on `gwSettledChainIds`.
      const ethBaseChainIds = gwSettledChainIds.filter((id) => {
        const cfg = state.chains!.config.find((c) => c.chainId === id);
        return !cfg?.baseToken || cfg.baseToken === ETH_TOKEN_ADDRESS;
      });
      expect(ethBaseChainIds.length, "at least one ETH-base GW-settled chain is expected").to.be.greaterThan(0);

      for (const chainId of ethBaseChainIds) {
        const l1Mig = await queryAssetMigrationNumber(
          l1Provider,
          l1AssetTrackerAddr,
          "L1AssetTracker",
          chainId,
          ethAssetId
        );
        const gwMig = await queryAssetMigrationNumber(
          gwProvider,
          GW_ASSET_TRACKER_ADDR,
          "GWAssetTracker",
          chainId,
          ethAssetId
        );

        expect(l1Mig, `L1AT assetMigrationNumber[${chainId}][ETH]`).to.be.gte(1);
        expect(l1Mig, `L1AT/GWAT assetMigrationNumber should match for chain ${chainId} (ETH)`).to.equal(gwMig);
      }
    });

    it("L1AT and GWAT assetMigrationNumber match for the NTV test token on every GW-settled chain", async () => {
      // Mirrors the source suite's "Correctly assigns chain token balances" check,
      // applied to the per-chain NTV test token that the anvil harness deploys and
      // migrates to GW during `registerAndMigrateTestTokens`.
      for (const chainId of gwSettledChainIds) {
        const tokenAddr = state.testTokens![chainId];
        if (!tokenAddr) continue;
        const testTokenAssetId = encodeNtvAssetId(chainId, tokenAddr);

        const l1Mig = await queryAssetMigrationNumber(
          l1Provider,
          l1AssetTrackerAddr,
          "L1AssetTracker",
          chainId,
          testTokenAssetId
        );
        const gwMig = await queryAssetMigrationNumber(
          gwProvider,
          GW_ASSET_TRACKER_ADDR,
          "GWAssetTracker",
          chainId,
          testTokenAssetId
        );

        expect(l1Mig, `L1AT assetMigrationNumber[${chainId}][testToken]`).to.be.gte(1);
        expect(l1Mig, `L1AT/GWAT assetMigrationNumber should match for chain ${chainId} (test token)`).to.equal(gwMig);
      }
    });

    // Note: the aggregate `sum(GW.chainBalance[c]) + sum(GW.pendingInteropBalance[c])
    // == L1.chainBalance[GW][ETH]` invariant does not hold exactly, because L1's
    // aggregate also accumulates the priority-tx base-cost overhead from every
    // L1→GW priority tx (the bookkeeping value paid into the GW mailbox at the
    // gateway level, not credited to a destination chain's per-chain balance).
    // Per-step exact accounting is instead asserted at the operation that moves
    // value: see "L1 deposit of a random amount populates GW chainBalance[chainId][ETH]"
    // (asserts exact equality against the deposit's `mintValue = amount + baseCost`)
    // and the reverse-TBM drain test (asserts post-drain GW `chainBalance == 0`).

    it("running TBM end-to-end for an already-migrated NTV test token is a no-op (idempotent)", async () => {
      // Test tokens are migrated to GW during `registerAndMigrateTestTokens` in
      // deployment-runner, so `assetMigrationNumber` is already at the chain's
      // current `migrationNumber` when this spec runs. Re-running the full TBM
      // flow — initiate on L2, finalise on L1, relay priority txs — must take
      // the early-return paths in `initiateL1ToGatewayMigrationOnL2` /
      // `receiveL1ToGatewayMigrationOnL1` without advancing any counter.
      const gwMigBefore = await queryAssetMigrationNumber(
        gwProvider,
        GW_ASSET_TRACKER_ADDR,
        "GWAssetTracker",
        reverseTbmChainId,
        reverseTbmTestTokenAssetId
      );
      const l1MigBefore = await queryAssetMigrationNumber(
        l1Provider,
        l1AssetTrackerAddr,
        "L1AssetTracker",
        reverseTbmChainId,
        reverseTbmTestTokenAssetId
      );
      expect(gwMigBefore, "setup guarantee: test token is already migrated on GW").to.be.gte(1);

      await migrateTokenBalanceToGW({
        l2Provider: reverseTbmProvider,
        l1Provider,
        gwProvider,
        chainId: reverseTbmChainId,
        assetId: reverseTbmTestTokenAssetId,
        l1AssetTrackerAddr,
        gwDiamondProxyAddr: gwDiamondProxy,
        l2DiamondProxyAddr: reverseTbmDiamondProxy,
      });

      const gwMigAfter = await queryAssetMigrationNumber(
        gwProvider,
        GW_ASSET_TRACKER_ADDR,
        "GWAssetTracker",
        reverseTbmChainId,
        reverseTbmTestTokenAssetId
      );
      const l1MigAfter = await queryAssetMigrationNumber(
        l1Provider,
        l1AssetTrackerAddr,
        "L1AssetTracker",
        reverseTbmChainId,
        reverseTbmTestTokenAssetId
      );
      expect(gwMigAfter, "already-migrated asset: GW assetMigrationNumber unchanged").to.equal(gwMigBefore);
      expect(l1MigAfter, "already-migrated asset: L1 assetMigrationNumber unchanged").to.equal(l1MigBefore);
      expect(l1MigAfter, "L1 and GW assetMigrationNumber agree").to.equal(gwMigAfter);
    });

    it("cannot initiate migration for a bogus assetId (AssetIdNotRegistered)", async () => {
      const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), reverseTbmProvider);
      const bogusAssetId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("bogus-asset-tbm-spec"));

      // The L2AssetTracker resolves the token via `_tryGetTokenAddress`, which
      // reverts with `AssetIdNotRegistered(bytes32)` when the asset isn't
      // registered on the NTV. This mirrors the source test assertion
      // (selector 0xda72d995 in zksync-era/token-balance-migration.test.ts).
      await expectRevert(
        () =>
          l2AssetTracker
            .connect(new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, reverseTbmProvider))
            .callStatic.initiateL1ToGatewayMigrationOnL2(bogusAssetId, { gasLimit: 5_000_000 }),
        "initiateL1ToGatewayMigrationOnL2 with bogus assetId",
        customError("L2AssetTracker", "AssetIdNotRegistered(bytes32)"),
        reverseTbmProvider
      );
    });

    it("assetMigrationNumber is 0 for an NTV-unregistered token", async () => {
      const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), reverseTbmProvider);

      const unmigrated = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("unmigrated-token-tbm-spec"));
      const ethMigNum = BigNumber.from(await l2AssetTracker.assetMigrationNumber(reverseTbmChainId, ethAssetId));
      const unmigratedMigNum = BigNumber.from(await l2AssetTracker.assetMigrationNumber(reverseTbmChainId, unmigrated));

      expect(ethMigNum.gt(0), `L2 assetMigrationNumber[${reverseTbmChainId}][ETH] > 0`).to.equal(true);
      expect(unmigratedMigNum.eq(0), "L2 assetMigrationNumber[·][unmigrated] == 0").to.equal(true);
    });

    it("cannot bridge out an NTV-registered-but-unmigrated token (TokenBalanceNotMigratedToGateway)", async () => {
      // Mirrors the source suite's "Cannot withdraw tokens that have not been
      // migrated" (selector 0x90ed63bb in zksync-era/token-balance-migration.test.ts).
      //
      // Setup: deploy a fresh TestnetERC20Token on the GW-settled chain and
      // register it on the L2 NTV. The NTV registration assigns an `assetId` and
      // records the token in `_tryGetTokenAddress`, but `assetMigrationNumber`
      // stays at 0 because we deliberately do NOT run TBM for it. Since the
      // chain's `migrationNumber` is 1 (migrated to GW during setup),
      // `_checkAssetMigrationNumber` must revert on any outbound bridge attempt.
      const deployerWallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, reverseTbmProvider);
      const erc20Factory = new ethers.ContractFactory(
        getAbi("TestnetERC20Token"),
        getCreationBytecode("TestnetERC20Token"),
        deployerWallet
      );
      const unmigratedToken = await erc20Factory.deploy("UnmigratedToken", "UNMIG", 18, {
        gasLimit: 5_000_000,
      });
      await unmigratedToken.deployed();

      const l2Ntv = new Contract(L2_NATIVE_TOKEN_VAULT_ADDR, getAbi("L2NativeTokenVault"), deployerWallet);
      const registerTx = await l2Ntv.registerToken(unmigratedToken.address, { gasLimit: 1_000_000 });
      await registerTx.wait();

      const unmigratedAssetId = encodeNtvAssetId(reverseTbmChainId, unmigratedToken.address);
      const unmigratedMigNum = BigNumber.from(
        await new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), reverseTbmProvider).assetMigrationNumber(
          reverseTbmChainId,
          unmigratedAssetId
        )
      );
      expect(unmigratedMigNum, "freshly-registered token starts at assetMigrationNumber=0").to.equal(0);

      // The only valid caller of `handleInitiateBridgingOnL2` is the L2 NTV, so
      // we impersonate it to exercise the exact same code path a production
      // outbound bridge would take. This is the same surface the source
      // `tokens.L2Native.withdraw(chainHandler)` call eventually reaches.
      await impersonateAndRun(reverseTbmProvider, L2_NATIVE_TOKEN_VAULT_ADDR, async (ntvSigner) => {
        const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), ntvSigner);
        await expectRevert(
          () =>
            l2AssetTracker.callStatic.handleInitiateBridgingOnL2(
              L1_CHAIN_ID,
              unmigratedAssetId,
              BigNumber.from(1),
              reverseTbmChainId,
              { gasLimit: 1_000_000 }
            ),
          "bridging out an unmigrated token",
          customError("L2AssetTracker", "TokenBalanceNotMigratedToGateway(bytes32,uint256,uint256)"),
          reverseTbmProvider
        );
      });
    });

    it("cannot send an interop bundle to an unregistered destination chain (DestinationChainNotRegistered)", async () => {
      const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, reverseTbmProvider);
      const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);
      const value = randomBigNumber(INTEROP_SMOKE_BUNDLE_VALUE_RANGE.min, INTEROP_SMOKE_BUNDLE_VALUE_RANGE.max);

      // `callStatic` surfaces the custom-error selector in the error data
      // (plain Anvil tx receipts strip revert data).
      await expectRevert(
        () => interopCenter.callStatic.sendBundle(UNREGISTERED_DESTINATION_BYTES, [], [], { gasLimit: 500_000, value }),
        "sendBundle to unregistered chain",
        customError("InteropCenter", "DestinationChainNotRegistered(uint256)"),
        reverseTbmProvider
      );
    });

    it("can withdraw the migrated NTV test token from the GW-settled chain post-TBM", async () => {
      // Mirrors the source suite's "Can withdraw tokens after migrating token
      // balances to gateway". The token was migrated to GW during
      // `registerAndMigrateTestTokens`, so `_checkAssetMigrationNumber` must
      // pass on the GW-settled chain and the L2 withdrawal must go through.
      const amount = randomBigNumber(TBM_WITHDRAWAL_AMOUNT_RANGE.min, TBM_WITHDRAWAL_AMOUNT_RANGE.max);
      const pending = await initiateErc20Withdrawal({
        l2RpcUrl: getL2RpcUrl(state, reverseTbmChainId),
        l1RpcUrl: getL1RpcUrl(state),
        chainId: reverseTbmChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l2TokenAddress: state.testTokens![reverseTbmChainId],
        // Test tokens in this harness are deployed on L2, so the assetId's
        // origin chain is the L2 chain id itself.
        tokenOriginChainId: reverseTbmChainId,
      });
      expect(pending.l2TxHash, "L2 withdraw tx hash").to.not.be.null;
      expect(pending.amount.eq(amount), "withdrawal captures the requested amount").to.equal(true);
    });
  });

  // ── Reverse TBM (GW → L1) ────────────────────────────────────────────
  //
  // Simulates the end state produced by `GatewayPreparation.startMigrateChainFromGateway`
  // and its sequencer-side finalisation, then exercises the real reverse-TBM entry point.
  // See the `harness-shims.simulateGWChainMigrationBurn` docstring for the full
  // production ↔ harness mapping.

  describe("Reverse TBM (GW → L1)", () => {
    let depositAmount: BigNumber;
    let l1GWBalanceBeforeDeposit: BigNumber;
    let gwBalanceBeforeDeposit: BigNumber;
    // Captured from each `initiateGatewayToL1MigrationOnGateway` tx so the
    // follow-up test can build an L1 finalisation payload from the same GW→L1
    // message. Keyed by asset (ETH, NTV test token) so we can finalise both.
    const gwToL1MigrationReceipts: Record<string, ethers.providers.TransactionReceipt> = {};
    // Withdrawals initiated on the chain after L1 sees the chain as migrated back
    // (L1 CAH `migrationNumber = 2`), but before L1 `chainBalance` is restored.
    // L1 finalisation must revert with `InsufficientChainBalance` here, and then
    // succeed after the reverse TBM completes. Mirrors the source suite's
    // `unfinalizedWithdrawals` → `withdrawals` lifecycle.
    const pendingWithdrawals: Record<string, PendingWithdrawal> = {};

    before(async () => {
      depositAmount = randomBigNumber(TBM_DEPOSIT_AMOUNT_RANGE.min, TBM_DEPOSIT_AMOUNT_RANGE.max);
      l1GWBalanceBeforeDeposit = await queryL1ChainBalance(l1Provider, l1AssetTrackerAddr, gwChainId, ethAssetId);
      gwBalanceBeforeDeposit = await getGWChainBalance(gwProvider, reverseTbmChainId, ethAssetId);
    });

    // Reverse-TBM asserts a strict, stateful sequence: (deposit → change SL → burn
    // migration on GW → initiate reverse TBM → assert state). The steps are
    // intentionally split into separate `it()` blocks so that each transition is an
    // independent, assertable observation, but they must run in declaration order —
    // Mocha's default ordering. This is consistent with how #2108's unbundle spec
    // structures its progressive tests.

    it("L1 deposit of a random amount populates GW chainBalance[chainId][ETH]", async () => {
      const result = await depositETHToL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, reverseTbmChainId),
        chainId: reverseTbmChainId,
        l1Addresses: state.l1Addresses!,
        amount: depositAmount,
        gwRpcUrl: getL2RpcUrl(state, gwChainId),
      });

      expect(result.l1TxHash, "L1 tx hash returned").to.not.be.null;

      // For a GW-settled chain the L1 deposit locks `mintValue = amount + baseCost`
      // on L1 (the full priority-tx value covering both the L2 mint and the L2 gas),
      // and GW credits that same `mintValue` to the migrating chain's balance
      // when it relays the priority tx. Both deltas must match exactly.
      const expectedDelta = result.mintValue;

      const gwBalanceAfter = await getGWChainBalance(gwProvider, reverseTbmChainId, ethAssetId);
      const gwDelta = gwBalanceAfter.sub(gwBalanceBeforeDeposit);
      expect(gwDelta.eq(expectedDelta), `GW chainBalance delta ${gwDelta} == mintValue ${expectedDelta}`).to.equal(
        true
      );

      const l1GWBalanceAfter = await queryL1ChainBalance(l1Provider, l1AssetTrackerAddr, gwChainId, ethAssetId);
      const l1GWDelta = l1GWBalanceAfter.sub(l1GWBalanceBeforeDeposit);
      expect(
        l1GWDelta.eq(expectedDelta),
        `L1 chainBalance[GW][ETH] delta ${l1GWDelta} == mintValue ${expectedDelta}`
      ).to.equal(true);
    });

    it("change L2 settlement layer back to L1 (real SystemContext path)", async () => {
      await setSettlementLayerViaBootloader({
        provider: reverseTbmProvider,
        settlementLayerChainId: L1_CHAIN_ID,
      });

      // L2ChainAssetHandler tracks the `migrationNumber[block.chainid]` transition
      // triggered by SystemContext; after SL change to L1 it reaches 2.
      const l2ChainAssetHandler = new Contract(
        L2_CHAIN_ASSET_HANDLER_ADDR,
        getAbi("L2ChainAssetHandler"),
        reverseTbmProvider
      );
      const l2MigNum: BigNumber = BigNumber.from(await l2ChainAssetHandler.migrationNumber(reverseTbmChainId));
      expect(
        l2MigNum.eq(POST_REVERSE_MIGRATION_NUMBER),
        `L2 L2ChainAssetHandler.migrationNumber[${reverseTbmChainId}] = ${l2MigNum} after SL change`
      ).to.equal(true);
    });

    it("apply the GW-side migration-burn transitions (settlement layer + migration number)", async () => {
      await simulateGWChainMigrationBurn({
        gwProvider,
        chainId: reverseTbmChainId,
        newSettlementLayerChainId: L1_CHAIN_ID,
        newMigrationNumber: POST_REVERSE_MIGRATION_NUMBER,
      });

      const bridgehub = new Contract(L2_BRIDGEHUB_ADDR, getAbi("L2Bridgehub"), gwProvider);
      const chainAssetHandler = new Contract(L2_CHAIN_ASSET_HANDLER_ADDR, getAbi("L2ChainAssetHandler"), gwProvider);
      const sl: BigNumber = BigNumber.from(await bridgehub.settlementLayer(reverseTbmChainId));
      const gwMigNum: BigNumber = BigNumber.from(await chainAssetHandler.migrationNumber(reverseTbmChainId));

      expect(sl.eq(L1_CHAIN_ID), `GW L2Bridgehub.settlementLayer[${reverseTbmChainId}] == L1`).to.equal(true);
      expect(
        gwMigNum.eq(POST_REVERSE_MIGRATION_NUMBER),
        `GW L2ChainAssetHandler.migrationNumber[${reverseTbmChainId}] == ${POST_REVERSE_MIGRATION_NUMBER}`
      ).to.equal(true);
    });

    it("reverse TBM: initiate on GW drains chainBalance for ETH + the NTV test token, advances their assetMigrationNumber to 2", async () => {
      // Drive the reverse-TBM initiate step for every asset we want to finalise
      // on L1 later: ETH (base token) and the NTV test token. Each invocation
      // drains the GW's per-chain `chainBalance[chainId][assetId]`, bumps the
      // GW asset-tracker's `assetMigrationNumber`, and emits the GW→L1 message
      // the L1 finalisation step consumes.
      const gwAssetTracker = new Contract(GW_ASSET_TRACKER_ADDR, getAbi("GWAssetTracker"), gwProvider);
      const gwWallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, gwProvider);

      const assetsToMigrate: Array<{ label: string; assetId: string }> = [
        { label: "baseToken", assetId: ethAssetId },
        { label: "testToken", assetId: reverseTbmTestTokenAssetId },
      ];

      for (const { label, assetId } of assetsToMigrate) {
        const tx = await gwAssetTracker
          .connect(gwWallet)
          .initiateGatewayToL1MigrationOnGateway(reverseTbmChainId, assetId, { gasLimit: 5_000_000 });
        gwToL1MigrationReceipts[label] = await tx.wait();

        const gwBalanceAfter = await getGWChainBalance(gwProvider, reverseTbmChainId, assetId);
        expect(gwBalanceAfter.eq(0), `GW chainBalance for ${label} drained to 0`).to.equal(true);

        const gwMig = await queryAssetMigrationNumber(
          gwProvider,
          GW_ASSET_TRACKER_ADDR,
          "GWAssetTracker",
          reverseTbmChainId,
          assetId
        );
        expect(gwMig, `GWAT assetMigrationNumber for ${label}`).to.equal(POST_REVERSE_MIGRATION_NUMBER);
      }
    });

    it("bump L1 ChainAssetHandler.migrationNumber to 2 via the dev setter (standing in for the chain-level migrate-from-gateway bridgeMint)", async () => {
      // In production, `L1ChainAssetHandler.migrationNumber[chainId]` is bumped
      // to `MIGRATION_NUMBER_SETTLEMENT_LAYER_TO_L1` (= 2) by `bridgeMint` at the
      // end of the chain-level migrate-from-gateway governance flow — a flow that
      // requires the migrating chain's Gateway diamond to satisfy
      // `Migrator.forwardedBridgeBurn` invariants (`priorityTree.getSize() == 0`
      // and `totalBatchesCommitted == totalBatchesExecuted`). The Anvil harness
      // has no sequencer or prover pipeline to satisfy those, so we drive the
      // same observable L1 state transition through the dev setter. See
      // `installL1ChainAssetHandlerDev` and `setL1ChainMigrationNumber`.
      await setL1ChainMigrationNumber({
        l1Provider,
        chainAssetHandlerProxy: l1ChainAssetHandlerProxy,
        chainId: reverseTbmChainId,
        newMigrationNumber: POST_REVERSE_MIGRATION_NUMBER,
      });

      const cah = new Contract(l1ChainAssetHandlerProxy, getAbi("L1ChainAssetHandler"), l1Provider);
      const l1CahMig: BigNumber = BigNumber.from(await cah.migrationNumber(reverseTbmChainId));
      expect(
        l1CahMig.eq(POST_REVERSE_MIGRATION_NUMBER),
        `L1 ChainAssetHandler.migrationNumber[${reverseTbmChainId}] == ${POST_REVERSE_MIGRATION_NUMBER}`
      ).to.equal(true);
    });

    it("flip L1 Bridgehub.settlementLayer back to L1 via forwardedBridgeMint (real onlyChainAssetHandler path)", async () => {
      // Completes the chain-migration-from-gateway on the L1 side by calling
      // `L1Bridgehub.forwardedBridgeMint(...)` from the L1ChainAssetHandler —
      // the exact caller surface production uses in `L1ChainAssetHandler.bridgeMint`.
      // After this step, L1 routes deposits/withdrawals for the chain through
      // the direct L1↔L2 path, which is what the source suite's
      // post-migrate-from-gateway tests (deposit, withdraw, finalise) rely on.
      await completeL1ChainMigrationSettlementLayer({
        l1Provider,
        chainAssetHandlerProxy: l1ChainAssetHandlerProxy,
        bridgehubAddr,
        chainId: reverseTbmChainId,
        baseTokenAssetId: ethAssetId,
        baseTokenOriginChainId: L1_CHAIN_ID,
        baseTokenOriginAddress: ETH_TOKEN_ADDRESS,
      });

      const l1Bridgehub = new Contract(bridgehubAddr, getAbi("IL1Bridgehub"), l1Provider);
      const sl: BigNumber = BigNumber.from(await l1Bridgehub.settlementLayer(reverseTbmChainId));
      expect(sl.eq(L1_CHAIN_ID), `L1 Bridgehub.settlementLayer[${reverseTbmChainId}] == L1`).to.equal(true);
    });

    it("withdraw ETH and the NTV test token from the chain (pending on L1 until reverse TBM completes)", async () => {
      // Mirrors the source suite's "Can withdraw tokens from the chain". With L1
      // now seeing the chain as migrated back (`chainAssetHandler.migrationNumber = 2`),
      // outbound withdrawals are routed through the L1-direct path, but L1's
      // `chainBalance[chainId][assetId]` is still drained until the reverse TBM
      // finalises — so the resulting L1 finalisations are expected to revert
      // until `receiveGatewayToL1MigrationOnL1` lands. We capture each
      // {@link PendingWithdrawal} here and drive its lifecycle in the two
      // tests below.
      const ethAmount = randomBigNumber(TBM_WITHDRAWAL_AMOUNT_RANGE.min, TBM_WITHDRAWAL_AMOUNT_RANGE.max);
      pendingWithdrawals.baseToken = await initiateEthWithdrawal({
        l2RpcUrl: getL2RpcUrl(state, reverseTbmChainId),
        l1RpcUrl: getL1RpcUrl(state),
        chainId: reverseTbmChainId,
        l1Addresses: state.l1Addresses!,
        amount: ethAmount,
      });

      const tokenAmount = randomBigNumber(TBM_WITHDRAWAL_AMOUNT_RANGE.min, TBM_WITHDRAWAL_AMOUNT_RANGE.max);
      pendingWithdrawals.testToken = await initiateErc20Withdrawal({
        l2RpcUrl: getL2RpcUrl(state, reverseTbmChainId),
        l1RpcUrl: getL1RpcUrl(state),
        chainId: reverseTbmChainId,
        l1Addresses: state.l1Addresses!,
        amount: tokenAmount,
        l2TokenAddress: state.testTokens![reverseTbmChainId],
        tokenOriginChainId: reverseTbmChainId,
      });

      expect(pendingWithdrawals.baseToken.l2TxHash, "ETH withdrawal L2 tx").to.not.be.null;
      expect(pendingWithdrawals.testToken.l2TxHash, "ERC20 withdrawal L2 tx").to.not.be.null;
    });

    it("cannot finalise pending withdrawals on L1 before reverse TBM completes (InsufficientChainBalance)", async () => {
      // Mirrors the source suite's "Cannot finalize pending withdrawals before
      // finalizing token balance migration to L1" (selector 0x07859b3b).
      // `L1AssetTracker._decreaseChainBalance` (invoked by `L1Nullifier.finalizeDeposit`)
      // reverts with this exact custom error when `chainBalance[chainId][assetId] < _amount`.
      const insufficientSelector = new ethers.utils.Interface(getAbi("L1AssetTracker")).getSighash(
        "InsufficientChainBalance(uint256,bytes32,uint256)"
      );
      for (const [label, pending] of Object.entries(pendingWithdrawals)) {
        const result = await finalizeWithdrawalOnL1(getL1RpcUrl(state), state.l1Addresses!, pending);
        expect(result.success, `${label} finalisation must revert before reverse TBM`).to.equal(false);
        expect(
          (result.revertData ?? "").toLowerCase().startsWith(insufficientSelector.toLowerCase()),
          `${label} revert data starts with InsufficientChainBalance selector ${insufficientSelector}; got revertData=${result.revertData?.slice(0, 32)}...`
        ).to.equal(true);
      }
    });

    it("finalise reverse TBM on L1 for ETH + test token, relay confirmations to GW and L2, assert all three sides reach assetMigrationNumber = 2", async () => {
      const l1Wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
      const l1AssetTracker = new Contract(l1AssetTrackerAddr, getAbi("L1AssetTracker"), l1Provider);

      const assetsToFinalise: Array<{ label: string; assetId: string; receiptLabel: string }> = [
        { label: "baseToken", assetId: ethAssetId, receiptLabel: "baseToken" },
        { label: "testToken", assetId: reverseTbmTestTokenAssetId, receiptLabel: "testToken" },
      ];

      for (const { label, assetId, receiptLabel } of assetsToFinalise) {
        const finalizeParams = buildFinalizeWithdrawalParams(gwToL1MigrationReceipts[receiptLabel], gwChainId);
        const l1BalanceBefore = await queryL1ChainBalance(l1Provider, l1AssetTrackerAddr, reverseTbmChainId, assetId);

        const tx = await l1AssetTracker
          .connect(l1Wallet)
          .receiveGatewayToL1MigrationOnL1(finalizeParams, { gasLimit: 10_000_000 });
        const l1Receipt = await tx.wait();

        // L1 assetMigrationNumber advances to the chain migration number.
        const l1AssetMig = await queryAssetMigrationNumber(
          l1Provider,
          l1AssetTrackerAddr,
          "L1AssetTracker",
          reverseTbmChainId,
          assetId
        );
        expect(l1AssetMig, `L1AT assetMigrationNumber for ${label}`).to.equal(POST_REVERSE_MIGRATION_NUMBER);

        // L1 chainBalance is restored by `_migrateFunds` in the finalisation path.
        const l1BalanceAfter = await queryL1ChainBalance(l1Provider, l1AssetTrackerAddr, reverseTbmChainId, assetId);
        expect(
          l1BalanceAfter.gte(l1BalanceBefore),
          `L1AT chainBalance for ${label} monotonically restored (${l1BalanceBefore} -> ${l1BalanceAfter})`
        ).to.equal(true);

        // Relay the confirmation priority txs the L1 receipt emitted: the
        // service tx targeting `GW_ASSET_TRACKER_ADDR` (confirmMigrationOnGateway)
        // goes to GW, and the one targeting `L2_ASSET_TRACKER_ADDR`
        // (confirmMigrationOnL2) goes to the migrating L2 chain. The L1→GW→L2
        // wrapping event on GW's L1 diamond is intentionally skipped: the
        // GW-side state is already migrated (via `simulateGWChainMigrationBurn`)
        // and the L1-side state is now too (via
        // `completeL1ChainMigrationSettlementLayer`), so the unwrapped priority
        // tx emitted by chain 12's own L1 diamond carries the confirmation
        // directly to L2.
        const gwConfirmationEvents = extractNewPriorityRequests(l1Receipt, gwDiamondProxy).filter(
          (r) => r.to.toLowerCase() === GW_ASSET_TRACKER_ADDR.toLowerCase()
        );
        const l2ConfirmationEvents = extractNewPriorityRequests(l1Receipt, reverseTbmDiamondProxy).filter(
          (r) => r.to.toLowerCase() === L2_ASSET_TRACKER_ADDR.toLowerCase()
        );
        expect(gwConfirmationEvents.length, `${label}: exactly one confirmMigrationOnGateway priority tx`).to.equal(1);
        expect(l2ConfirmationEvents.length, `${label}: exactly one confirmMigrationOnL2 priority tx`).to.equal(1);

        for (const req of gwConfirmationEvents) {
          const result = await relayTx(gwProvider, req.from, req.to, req.calldata, req.value);
          expect(result.success, `${label} confirmMigrationOnGateway relay`).to.equal(true);
        }
        for (const req of l2ConfirmationEvents) {
          const result = await relayTx(reverseTbmProvider, req.from, req.to, req.calldata, req.value);
          expect(result.success, `${label} confirmMigrationOnL2 relay`).to.equal(true);
        }

        const gwAssetMigPost = await queryAssetMigrationNumber(
          gwProvider,
          GW_ASSET_TRACKER_ADDR,
          "GWAssetTracker",
          reverseTbmChainId,
          assetId
        );
        expect(gwAssetMigPost, `GWAT assetMigrationNumber for ${label} post-confirmation`).to.equal(
          POST_REVERSE_MIGRATION_NUMBER
        );

        const l2AssetMigPost = await queryAssetMigrationNumber(
          reverseTbmProvider,
          L2_ASSET_TRACKER_ADDR,
          "L2AssetTracker",
          reverseTbmChainId,
          assetId
        );
        expect(l2AssetMigPost, `L2AT assetMigrationNumber for ${label} post-confirmation`).to.equal(
          POST_REVERSE_MIGRATION_NUMBER
        );
      }
    });

    it("can finalise pending withdrawals on L1 now that reverse TBM has restored chainBalance", async () => {
      // Mirrors the source suite's "Can finalize pending withdrawals after
      // migrating token balances from gateway". The reverse-TBM finalisation
      // above called `_migrateFunds` inside `L1AssetTracker.receiveGatewayToL1MigrationOnL1`,
      // restoring `L1AssetTracker.chainBalance[chainId][assetId]` to a value
      // that covers each pending withdrawal. The same finalisation call that
      // reverted with `InsufficientChainBalance` above now lands.
      for (const [label, pending] of Object.entries(pendingWithdrawals)) {
        const result = await finalizeWithdrawalOnL1(getL1RpcUrl(state), state.l1Addresses!, pending);
        expect(
          result.success,
          `${label} finalisation after reverse TBM: ${result.errorMessage?.slice(0, 200)}`
        ).to.equal(true);
      }
    });

    it("depositing a fresh L1-native ERC20 to the chain after reverse TBM shows L1AT = 2 and no GW tracking", async () => {
      // Mirrors the source suite's "Can deposit a token to the chain after
      // migrating from gateway". L1's `ChainAssetHandler.migrationNumber[chainId]`
      // is now 2, so when the new asset registers on the L1 NTV its
      // `assetMigrationNumber` is set to the chain's current migration number
      // (`_forceSetAssetMigrationNumber(2)`) on L1; GW never sees it, so its
      // GWAT entry stays at 0.
      const deployer = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider);
      const factory = new ethers.ContractFactory(
        getAbi("TestnetERC20Token"),
        getCreationBytecode("TestnetERC20Token"),
        deployer
      );
      const freshL1Token = await factory.deploy("PostMigrateToken", "PMT", 18, { gasLimit: 5_000_000 });
      await freshL1Token.deployed();
      const mintAmount = ethers.utils.parseUnits("1000", 18);
      await (await freshL1Token.mint(deployer.address, mintAmount, { gasLimit: 500_000 })).wait();

      const depositAmount = randomBigNumber(TBM_WITHDRAWAL_AMOUNT_RANGE.min, TBM_WITHDRAWAL_AMOUNT_RANGE.max.mul(10));
      const depositResult = await depositERC20ToL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, reverseTbmChainId),
        chainId: reverseTbmChainId,
        l1Addresses: state.l1Addresses!,
        tokenAddress: freshL1Token.address,
        amount: depositAmount,
      });
      expect(depositResult.l1TxHash, "L1 deposit tx hash").to.not.be.null;

      const freshAssetId = depositResult.assetId;
      const l1Mig = await queryAssetMigrationNumber(
        l1Provider,
        l1AssetTrackerAddr,
        "L1AssetTracker",
        reverseTbmChainId,
        freshAssetId
      );
      const gwMig = await queryAssetMigrationNumber(
        gwProvider,
        GW_ASSET_TRACKER_ADDR,
        "GWAssetTracker",
        reverseTbmChainId,
        freshAssetId
      );
      expect(l1Mig, "L1AT assetMigrationNumber matches chain's post-reverse-TBM migrationNumber").to.equal(
        POST_REVERSE_MIGRATION_NUMBER
      );
      expect(gwMig, "GWAT assetMigrationNumber stays at 0 for a token deposited after reverse TBM").to.equal(0);
    });

    it("reverse TBM is idempotent — repeating it on GW reverts with InvalidAssetMigrationNumber", async () => {
      const gwAssetTracker = new Contract(GW_ASSET_TRACKER_ADDR, getAbi("GWAssetTracker"), gwProvider);
      const gwWallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, gwProvider);

      // `callStatic` surfaces the custom-error selector from the revert; plain
      // tx receipts on Anvil strip the revert data and just report "reverted".
      await expectRevert(
        () =>
          gwAssetTracker
            .connect(gwWallet)
            .callStatic.initiateGatewayToL1MigrationOnGateway(reverseTbmChainId, ethAssetId, { gasLimit: 5_000_000 }),
        "reverse TBM replay",
        customError("GWAssetTracker", "InvalidAssetMigrationNumber()"),
        gwProvider
      );
    });
  });
});

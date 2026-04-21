/**
 * 10 - Token Balance Migration Lifecycle
 *
 * Exercises the end-to-end Token Balance Migration (TBM) flow across L1, GW and an
 * L2 chain, with negative-path checks at each stage and conservation invariants.
 *
 * Covered stages:
 *
 *   - Pre-migration state on the direct-settled chain (interop sending is rejected
 *     until the chain is migrated to GW).
 *   - Forward TBM (L1 → GW) for ETH and an NTV test token, verifying that the L1
 *     and GW sides agree on `assetMigrationNumber` and that the GW per-chain
 *     `chainBalance` is bounded by the L1 `chainBalance[GW][ETH]`.
 *   - Reverse TBM (GW → L1) after the GW-settled chain is migrated back to L1,
 *     driven by:
 *       - `setSettlementLayerViaBootloader` on the L2 side (real SystemContext path),
 *       - `simulateGWChainMigrationBurn` on the GW side, which reproduces the two
 *         observable effects of production `bridgeBurn` via the real Solidity entry
 *         points (see `harness-shims.ts` for the full rationale).
 *
 * Chain topology (see `config/anvil-config.json`):
 *
 *   Chain 10  — direct-settled on L1, `migrationNumber = 0`.
 *   Chain 11  — GW.
 *   Chain 12  — GW-settled, `migrationNumber = 1` after gateway setup.
 *   Chain 13  — GW-settled, `migrationNumber = 1`.
 *   Chain 14  — GW-settled, custom ERC20 base token (added in #2108).
 */

import { expect } from "chai";
import { BigNumber, Contract, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import {
  getChainIdByRole,
  getChainIdsByRole,
  getChainDiamondProxy,
  getL1RpcUrl,
  getL2RpcUrl,
  buildMockInteropProof,
} from "../../src/core/utils";
import { getAbi } from "../../src/core/contracts";
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
} from "../../src/core/const";
import { migrateTokenBalanceToGW } from "../../src/helpers/token-balance-migration-helper";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import {
  installL2ChainAssetHandlerDev,
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
const INTEROP_SMOKE_BUNDLE_VALUE_RANGE = {
  min: BigNumber.from(1),
  max: BigNumber.from(1_000_000),
};

async function queryMigrationNumber(
  provider: ethers.providers.JsonRpcProvider,
  contractAddr: string,
  contractName: "L1AssetTracker" | "GWAssetTracker" | "L2AssetTracker",
  chainId: number,
  assetId: string
): Promise<number> {
  const contract = new Contract(contractAddr, getAbi(contractName), provider);
  const result = await contract.assetMigrationNumber(chainId, assetId);
  return BigNumber.from(result).toNumber();
}

async function queryL1ChainBalance(
  l1Provider: ethers.providers.JsonRpcProvider,
  l1AssetTrackerAddr: string,
  chainId: number,
  assetId: string
): Promise<BigNumber> {
  const contract = new Contract(l1AssetTrackerAddr, getAbi("L1AssetTracker"), l1Provider);
  return contract.chainBalance(chainId, assetId);
}

describe("10 - Token Balance Migration Lifecycle", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  // Chain topology
  let gwChainId: number;
  let gwSettledChainIds: number[];
  let directSettledChainId: number;
  // The GW-settled chain that is the subject of the reverse-TBM flow.
  let reverseTbmChainId: number;

  // Providers
  let l1Provider: ethers.providers.JsonRpcProvider;
  let gwProvider: ethers.providers.JsonRpcProvider;
  let directProvider: ethers.providers.JsonRpcProvider;
  let reverseTbmProvider: ethers.providers.JsonRpcProvider;

  // Addresses
  let l1AssetTrackerAddr: string;
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
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");
    reverseTbmChainId = gwSettledChainIds[0];

    l1Provider = new ethers.providers.JsonRpcProvider(getL1RpcUrl(state));
    gwProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, gwChainId));
    directProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, directSettledChainId));
    reverseTbmProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, reverseTbmChainId));

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
  });

  // ── Pre-migration state on the direct-settled chain ─────────────────

  describe("Pre-migration state (direct-settled chain)", () => {
    it("L1AT assetMigrationNumber is 0 for a direct-settled chain (ETH)", async () => {
      const migNum = await queryMigrationNumber(
        l1Provider,
        l1AssetTrackerAddr,
        "L1AssetTracker",
        directSettledChainId,
        ethAssetId
      );
      expect(migNum, `L1AT assetMigrationNumber[${directSettledChainId}][ETH]`).to.equal(0);
    });

    it("cannot send an interop bundle from a direct-settled chain (NotInGatewayMode)", async () => {
      const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, directProvider);
      const interopCenter = new Contract(INTEROP_CENTER_ADDR, getAbi("InteropCenter"), wallet);
      // Chain-less ERC-7930 encoding of a dummy destination — the function reverts
      // before decoding because the caller's settlement layer is L1. We use
      // `callStatic` rather than sending a tx so the custom-error selector is
      // exposed in the error data (Anvil does not surface it on tx receipts).
      const destinationBytes = "0x00010000010d00";

      await expectRevert(
        () => interopCenter.callStatic.sendBundle(destinationBytes, [], [], { gasLimit: 500_000, value: 0 }),
        "sendBundle from direct-settled chain",
        customError("InteropCenter", "NotInGatewayMode()"),
        directProvider
      );
    });

    it("cannot execute an interop bundle on a direct-settled chain", async () => {
      const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, directProvider);
      const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);
      const dummyProof = buildMockInteropProof(gwSettledChainIds[0]);

      await expectRevert(
        () => interopHandler.executeBundle("0x", dummyProof, { gasLimit: 500_000 }).then((tx) => tx.wait()),
        "executeBundle on direct-settled chain"
      );
    });

    it("cannot unbundle an interop bundle on a direct-settled chain", async () => {
      const wallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, directProvider);
      const interopHandler = new Contract(L2_INTEROP_HANDLER_ADDR, getAbi("InteropHandler"), wallet);

      await expectRevert(
        () => interopHandler.unbundleBundle("0x", [], { gasLimit: 500_000 }).then((tx) => tx.wait()),
        "unbundleBundle on direct-settled chain"
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
        const l1Mig = await queryMigrationNumber(l1Provider, l1AssetTrackerAddr, "L1AssetTracker", chainId, ethAssetId);
        const gwMig = await queryMigrationNumber(
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

    it("sum of GW per-chain balances is <= L1 chainBalance[GW][ETH] (conservation)", async () => {
      const l1GWBalance = await queryL1ChainBalance(l1Provider, l1AssetTrackerAddr, gwChainId, ethAssetId);

      let gwTotal = BigNumber.from(0);
      for (const chainId of gwSettledChainIds) {
        const bal = await getGWChainBalance(gwProvider, chainId, ethAssetId);
        gwTotal = gwTotal.add(bal);
      }

      expect(gwTotal.lte(l1GWBalance), `gwTotal=${gwTotal}, L1AT[GW][ETH]=${l1GWBalance}`).to.equal(true);
    });

    it("running TBM end-to-end for an already-migrated NTV test token is a no-op (idempotent)", async () => {
      // Test tokens are migrated to GW during `registerAndMigrateTestTokens` in
      // deployment-runner, so `assetMigrationNumber` is already at the chain's
      // current `migrationNumber` when this spec runs. Re-running the full TBM
      // flow — initiate on L2, finalise on L1, relay priority txs — must take
      // the early-return paths in `initiateL1ToGatewayMigrationOnL2` /
      // `receiveL1ToGatewayMigrationOnL1` without advancing any counter.
      const gwMigBefore = await queryMigrationNumber(
        gwProvider,
        GW_ASSET_TRACKER_ADDR,
        "GWAssetTracker",
        reverseTbmChainId,
        reverseTbmTestTokenAssetId
      );
      const l1MigBefore = await queryMigrationNumber(
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

      const gwMigAfter = await queryMigrationNumber(
        gwProvider,
        GW_ASSET_TRACKER_ADDR,
        "GWAssetTracker",
        reverseTbmChainId,
        reverseTbmTestTokenAssetId
      );
      const l1MigAfter = await queryMigrationNumber(
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

    it("cannot initiate migration for a bogus assetId (NTV lookup fails)", async () => {
      const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), reverseTbmProvider);
      const bogusAssetId = ethers.utils.keccak256(ethers.utils.toUtf8Bytes("bogus-asset-tbm-spec"));

      // The L2AssetTracker tries to resolve the token via `_tryGetTokenAddress`,
      // which reverts when the asset isn't registered on the NTV. No specific
      // selector is asserted because the revert bubbles up from the NTV and is
      // not part of L2AssetTracker's custom error surface.
      await expectRevert(
        () =>
          l2AssetTracker
            .connect(new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, reverseTbmProvider))
            .callStatic.initiateL1ToGatewayMigrationOnL2(bogusAssetId, { gasLimit: 5_000_000 }),
        "initiateL1ToGatewayMigrationOnL2 with bogus assetId"
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

      // GW chainBalance must have grown by at least `depositAmount` (exact match is
      // not asserted because the deposit flow debits a small base-token fee via
      // priority tx bookkeeping that already lived on the chain pre-deposit).
      const gwBalanceAfter = await getGWChainBalance(gwProvider, reverseTbmChainId, ethAssetId);
      const gwDelta = gwBalanceAfter.sub(gwBalanceBeforeDeposit);
      expect(gwDelta.gte(depositAmount), `GW chainBalance delta ${gwDelta} >= deposit ${depositAmount}`).to.equal(true);

      // L1 chainBalance[GW][ETH] is the aggregate that funds all GW-settled chains
      // and must also have grown by at least `depositAmount`.
      const l1GWBalanceAfter = await queryL1ChainBalance(l1Provider, l1AssetTrackerAddr, gwChainId, ethAssetId);
      expect(
        l1GWBalanceAfter.sub(l1GWBalanceBeforeDeposit).gte(depositAmount),
        "L1 chainBalance[GW][ETH] grows by at least the deposit amount"
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

    it("initiating reverse TBM drains GW chainBalance and advances assetMigrationNumber to 2", async () => {
      const gwBalanceBefore = await getGWChainBalance(gwProvider, reverseTbmChainId, ethAssetId);
      expect(gwBalanceBefore.gt(0), "GW chainBalance > 0 before reverse TBM").to.equal(true);

      const gwAssetTracker = new Contract(GW_ASSET_TRACKER_ADDR, getAbi("GWAssetTracker"), gwProvider);
      const gwWallet = new ethers.Wallet(ANVIL_DEFAULT_PRIVATE_KEY, gwProvider);

      const tx = await gwAssetTracker
        .connect(gwWallet)
        .initiateGatewayToL1MigrationOnGateway(reverseTbmChainId, ethAssetId, { gasLimit: 5_000_000 });
      await tx.wait();

      const gwBalanceAfter = await getGWChainBalance(gwProvider, reverseTbmChainId, ethAssetId);
      expect(gwBalanceAfter.eq(0), `GW chainBalance drained to 0 (was ${gwBalanceAfter})`).to.equal(true);

      const gwMig = await queryMigrationNumber(
        gwProvider,
        GW_ASSET_TRACKER_ADDR,
        "GWAssetTracker",
        reverseTbmChainId,
        ethAssetId
      );
      expect(gwMig, "GWAT assetMigrationNumber == 2 after reverse TBM").to.equal(POST_REVERSE_MIGRATION_NUMBER);
    });

    it("reverse TBM is idempotent — repeating it reverts with InvalidAssetMigrationNumber", async () => {
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

    it("L2 assetMigrationNumber still lags GW (stays at 1 pending L1 finalisation)", async () => {
      // `L2AssetTracker.assetMigrationNumber` for ETH is only advanced once the L1
      // finalisation round-trip completes and emits the confirmation priority tx
      // back to L2. This test does not drive that step; spec 10 keeps the scope
      // limited to the GW-side effects of reverse TBM initiation.
      const l2AssetTracker = new Contract(L2_ASSET_TRACKER_ADDR, getAbi("L2AssetTracker"), reverseTbmProvider);
      const ethMigNum = BigNumber.from(await l2AssetTracker.assetMigrationNumber(reverseTbmChainId, ethAssetId));
      expect(ethMigNum.eq(1), `L2 assetMigrationNumber[${reverseTbmChainId}][ETH] pending L1 finalisation`).to.equal(
        true
      );
    });
  });
});

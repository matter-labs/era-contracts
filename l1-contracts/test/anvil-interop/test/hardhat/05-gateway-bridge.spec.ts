import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { createBalanceTrackerFromState, queryEthAssetIdFromState } from "../../src/helpers/balance-tracker";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import {
  buildAssetRouterWithdrawalLog,
  callProcessLogsAndMessages,
  getGWChainBalance,
} from "../../src/helpers/process-logs-helper";
import { migrateTokenBalanceToGW } from "../../src/helpers/token-balance-migration-helper";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ETH_TOKEN_ADDRESS, L1_CHAIN_ID } from "../../src/core/const";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import { getL2Chain, getChainDiamondProxy, getChainIdByRole, getChainIdsByRole } from "../../src/core/utils";

describe("05 - Gateway Bridge (GW-settled chain, via GW)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let gwChainId: number;
  let gwSettledChainId: number;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    gwChainId = getChainIdByRole(state.chains.config, "gateway");
    gwSettledChainId = getChainIdsByRole(state.chains.config, "gwSettled")[0];
  });

  describe("ETH deposits L1 -> GW-settled chain through gateway", () => {
    it("deposits ETH from L1 to GW-settled chain", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const assetId = await queryEthAssetIdFromState(state);
      const amount = ethers.utils.parseEther("0.5");
      const l2Chain = getL2Chain(state.chains!, gwSettledChainId);
      const gwChain = getL2Chain(state.chains!, gwChainId);

      // For gateway-settled chains, L1AssetTracker tracks balance under the GW chain ID
      const before = await tracker.takeChainBalanceSnapshot(gwChainId, assetId, true);

      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        gwRpcUrl: gwChain.rpcUrl,
      });

      expect(result.l1TxHash).to.not.be.null;

      const after = await tracker.takeChainBalanceSnapshot(gwChainId, assetId, true);

      const l1ChainBalanceDelta = BigNumber.from(after.l1ChainBalance).sub(before.l1ChainBalance);
      expect(
        l1ChainBalanceDelta.eq(result.mintValue),
        `L1AssetTracker.chainBalance[GW] should increase by ${result.mintValue.toString()}, got ${l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      console.log(`   L1AssetTracker.chainBalance[${gwChainId}]: ${BigNumber.from(after.l1ChainBalance).toString()}`);
    });
  });

  describe("ETH withdrawals GW-settled chain -> L1 through gateway", () => {
    it("withdraws ETH from GW-settled chain to L1", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const assetId = await queryEthAssetIdFromState(state);
      const amount = ethers.utils.parseEther("0.2");
      const l2Chain = getL2Chain(state.chains!, gwSettledChainId);

      const before = await tracker.takeChainBalanceSnapshot(gwChainId, assetId, true);

      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
      });

      expect(result.l2TxHash).to.not.be.null;

      const after = await tracker.takeChainBalanceSnapshot(gwChainId, assetId, true);

      const l1ChainBalanceDelta = BigNumber.from(before.l1ChainBalance).sub(after.l1ChainBalance);
      expect(
        l1ChainBalanceDelta.eq(amount),
        `L1AssetTracker.chainBalance[GW] should decrease by ${amount.toString()}, got ${l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      console.log(`   L1AssetTracker.chainBalance[${gwChainId}]: ${BigNumber.from(after.l1ChainBalance).toString()}`);
    });
  });

  describe("processLogsAndMessages on GW for withdrawal", () => {
    it("processes a withdrawal log and decreases GWAssetTracker.chainBalance", async () => {
      const gwChain = getL2Chain(state.chains!, gwChainId);
      const gwProvider = new ethers.providers.JsonRpcProvider(gwChain.rpcUrl);

      const assetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
      const withdrawalAmount = ethers.utils.parseEther("0.1");
      const wallet = ANVIL_DEFAULT_ACCOUNT_ADDR;

      // Establish GWAssetTracker.chainBalance via the full Token Balance Migration flow
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const l2Chain = getL2Chain(state.chains!, gwSettledChainId);
      const l2Provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);
      const gwDiamondProxy = getChainDiamondProxy(state.chainAddresses!, gwChainId);
      const l2DiamondProxy = getChainDiamondProxy(state.chainAddresses!, gwSettledChainId);

      await migrateTokenBalanceToGW({
        l2Provider,
        l1Provider,
        gwProvider,
        chainId: gwSettledChainId,
        assetId,
        l1AssetTrackerAddr: state.l1Addresses!.l1AssetTracker,
        gwDiamondProxyAddr: gwDiamondProxy,
        l2DiamondProxyAddr: l2DiamondProxy,
        logger: (line) => console.log(line),
      });

      const gwBalanceBefore = await getGWChainBalance(gwProvider, gwSettledChainId, assetId);
      console.log(`   GWAssetTracker.chainBalance[${gwSettledChainId}] before: ${gwBalanceBefore.toString()}`);

      const { log: withdrawalLog, message } = buildAssetRouterWithdrawalLog({
        txNumberInBatch: 0,
        assetId,
        amount: withdrawalAmount,
        receiver: wallet,
        originToken: ETH_TOKEN_ADDRESS,
        originalCaller: wallet,
        tokenOriginChainId: L1_CHAIN_ID,
      });

      const result = await callProcessLogsAndMessages({
        gwProvider,
        gwRpcUrl: gwChain.rpcUrl,
        chainId: gwSettledChainId,
        logs: [withdrawalLog],
        messages: [message],
        logger: (line) => console.log(line),
      });

      expect(result.txHash).to.not.be.null;

      const gwBalanceAfter = await getGWChainBalance(gwProvider, gwSettledChainId, assetId);
      console.log(`   GWAssetTracker.chainBalance[${gwSettledChainId}] after: ${gwBalanceAfter.toString()}`);

      const gwBalanceDelta = gwBalanceBefore.sub(gwBalanceAfter);
      expect(
        gwBalanceDelta.eq(withdrawalAmount),
        `GWAssetTracker.chainBalance[${gwSettledChainId}] should decrease by ${withdrawalAmount.toString()}, got ${gwBalanceDelta.toString()}`
      ).to.equal(true);
    });
  });

  describe("Token balance migration consistency", () => {
    it("sum of GW per-chain balances <= L1 GW balance", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const assetId = await queryEthAssetIdFromState(state);
      const gwChain = getL2Chain(state.chains!, gwChainId);
      const gwProvider = new ethers.providers.JsonRpcProvider(gwChain.rpcUrl);

      const l1Snapshot = await tracker.takeChainBalanceSnapshot(gwChainId, assetId, true);
      const l1GWBalance = BigNumber.from(l1Snapshot.l1ChainBalance);

      const gwSettledChainIds = getChainIdsByRole(state.chains!.config, "gwSettled");
      let gwTotalBalance = BigNumber.from(0);
      for (const chainId of gwSettledChainIds) {
        const bal = await getGWChainBalance(gwProvider, chainId, assetId);
        gwTotalBalance = gwTotalBalance.add(bal);
        console.log(`   GWAssetTracker.chainBalance[${chainId}]: ${bal.toString()}`);
      }

      console.log(`   L1AssetTracker.chainBalance[${gwChainId}] (total): ${l1GWBalance.toString()}`);
      console.log(`   Sum of GW per-chain balances: ${gwTotalBalance.toString()}`);

      expect(
        gwTotalBalance.lte(l1GWBalance),
        `Sum of GW chain balances (${gwTotalBalance.toString()}) should be <= L1 GW balance (${l1GWBalance.toString()})`
      ).to.equal(true);
    });
  });
});

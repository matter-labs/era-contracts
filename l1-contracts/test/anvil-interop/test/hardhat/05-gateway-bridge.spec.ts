import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import {
  createBalanceTrackerFromState,
  computeBalanceDeltas,
  queryEthAssetIdFromState,
} from "../../src/helpers/balance-tracker";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import {
  buildAssetRouterWithdrawalLog,
  callProcessLogsAndMessages,
  getGWChainBalance,
} from "../../src/helpers/process-logs-helper";
import { migrateTokenBalanceToGW } from "../../src/helpers/token-balance-migration-helper";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_RECIPIENT_ADDR, ETH_TOKEN_ADDRESS, L1_CHAIN_ID } from "../../src/core/const";
import { encodeNtvAssetId } from "../../src/core/data-encoding";
import {
  getL1RpcUrl,
  getL2RpcUrl,
  getChainDiamondProxy,
  getChainIdByRole,
  getChainIdsByRole,
} from "../../src/core/utils";

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
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;

      // For gateway-settled chains, L1AssetTracker tracks balance under the GW chain ID.
      const senderBefore = await tracker.takeSnapshot(gwChainId, assetId, undefined, undefined, senderAddr, true);

      const result = await depositETHToL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        gwRpcUrl: getL2RpcUrl(state, gwChainId),
      });

      expect(result.l1TxHash).to.not.be.null;

      const senderAfter = await tracker.takeSnapshot(gwChainId, assetId, undefined, undefined, senderAddr, true);
      const deltas = computeBalanceDeltas(senderBefore, senderAfter);

      // L1AssetTracker.chainBalance[gwChainId] should increase by mintValue
      expect(
        deltas.l1ChainBalanceDelta.eq(result.mintValue),
        `L1AssetTracker.chainBalance[GW] should increase by ${result.mintValue.toString()}, got ${deltas.l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      // Sender's L1 ETH balance should decrease (by at least mintValue; gas adds to the decrease)
      expect(
        deltas.l1TokenDelta.lte(result.mintValue.mul(-1)),
        `Sender L1 ETH should decrease by at least ${result.mintValue.toString()}, got delta ${deltas.l1TokenDelta.toString()}`
      ).to.equal(true);

      console.log(
        `   L1AssetTracker.chainBalance[${gwChainId}]: ${BigNumber.from(senderAfter.l1ChainBalance).toString()}`
      );
    });
  });

  describe("ETH withdrawals GW-settled chain -> L1 through gateway", () => {
    it("withdraws ETH from GW-settled chain to L1", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const assetId = await queryEthAssetIdFromState(state);
      const amount = ethers.utils.parseEther("0.2");
      const recipientAddr = ANVIL_RECIPIENT_ADDR;

      // Snapshot chain balances and recipient's L1 balance
      const chainBefore = await tracker.takeChainBalanceSnapshot(gwChainId, assetId, true);
      const recipientL1Before = await tracker.getL1EthBalance(recipientAddr);

      const result = await withdrawETHFromL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1Recipient: recipientAddr,
      });

      expect(result.l2TxHash).to.not.be.null;

      const chainAfter = await tracker.takeChainBalanceSnapshot(gwChainId, assetId, true);
      const recipientL1After = await tracker.getL1EthBalance(recipientAddr);

      // L1AssetTracker.chainBalance[gwChainId] should decrease by the withdrawal amount
      const l1ChainBalanceDelta = BigNumber.from(chainBefore.l1ChainBalance).sub(chainAfter.l1ChainBalance);
      expect(
        l1ChainBalanceDelta.eq(amount),
        `L1AssetTracker.chainBalance[GW] should decrease by ${amount.toString()}, got ${l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      // Recipient's L1 ETH balance should increase by exactly the withdrawal amount
      const recipientL1Delta = recipientL1After.sub(recipientL1Before);
      expect(
        recipientL1Delta.eq(amount),
        `Recipient L1 ETH balance should increase by ${amount.toString()}, got delta ${recipientL1Delta.toString()}`
      ).to.equal(true);

      console.log(
        `   L1AssetTracker.chainBalance[${gwChainId}]: ${BigNumber.from(chainAfter.l1ChainBalance).toString()}`
      );
      console.log(`   Recipient L1 ETH balance delta: ${ethers.utils.formatEther(recipientL1Delta)} ETH`);
    });
  });

  describe("processLogsAndMessages on GW for withdrawal", () => {
    it("processes a withdrawal log and decreases GWAssetTracker.chainBalance", async () => {
      const gwProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, gwChainId));

      const assetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
      const withdrawalAmount = ethers.utils.parseEther("0.1");
      const wallet = ANVIL_DEFAULT_ACCOUNT_ADDR;

      // Establish GWAssetTracker.chainBalance via the full Token Balance Migration flow
      const l1Provider = new ethers.providers.JsonRpcProvider(getL1RpcUrl(state));
      const l2Provider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, gwSettledChainId));
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
        gwRpcUrl: getL2RpcUrl(state, gwChainId),
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
      const gwProvider = new ethers.providers.JsonRpcProvider(getL2RpcUrl(state, gwChainId));

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

import { expect } from "chai";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { createBalanceTrackerFromState, queryEthAssetId } from "../../src/balance-tracker";
import { depositETHToL2 } from "../../src/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/l2-withdrawal-helper";
import {
  buildAssetRouterWithdrawalLog,
  callProcessLogsAndMessages,
  getGWChainBalance,
} from "../../src/process-logs-helper";
import { migrateTokenBalanceToGW } from "../../src/token-balance-migration-helper";
import { ETH_TOKEN_ADDRESS, L1_CHAIN_ID } from "../../src/const";
import { encodeNtvAssetId } from "../../src/data-encoding";

const L2A_CHAIN_ID = 12; // GW-settled chain
const GW_CHAIN_ID = 11;

describe("05 - Gateway Bridge (Chain 12, via GW)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
  });

  describe("ETH deposits L1 -> L2A through gateway", () => {
    it("deposits ETH from L1 to L2A", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const amount = ethers.utils.parseEther("0.5");
      const l2Chain = state.chains!.l2.find((c) => c.chainId === L2A_CHAIN_ID)!;
      const gwChain = state.chains!.l2.find((c) => c.chainId === GW_CHAIN_ID)!;
      const gwDiamondProxy = state.chainAddresses!.find((c) => c.chainId === GW_CHAIN_ID)!.diamondProxy;

      // For gateway-settled chains, L1AssetTracker tracks the balance under the
      // settlement layer chain ID (GW), not the destination chain ID (L2A).
      const l1ChainBalanceBefore = await tracker.getL1ChainBalance(GW_CHAIN_ID, assetId);

      // Execute deposit — relay through GW so GWAssetTracker.chainBalance[L2A] is updated
      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: L2A_CHAIN_ID,
        l1Addresses: state.l1Addresses!,
        amount,
        l1DiamondProxy: gwDiamondProxy,
        gwRpcUrl: gwChain.rpcUrl,
      });

      expect(result.l1TxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

      const l1ChainBalanceAfter = await tracker.getL1ChainBalance(GW_CHAIN_ID, assetId);

      // Verify L1AssetTracker.chainBalance[GW] increased by mintValue
      const l1ChainBalanceDelta = l1ChainBalanceAfter.sub(l1ChainBalanceBefore);
      expect(
        l1ChainBalanceDelta.eq(result.mintValue),
        `L1AssetTracker.chainBalance[${GW_CHAIN_ID}] should increase by ${result.mintValue.toString()}, got ${l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      console.log(`   L1AssetTracker.chainBalance[${GW_CHAIN_ID}]: ${l1ChainBalanceAfter.toString()}`);
    });
  });

  describe("ETH withdrawals L2A -> L1 through gateway", () => {
    it("withdraws ETH from L2A to L1", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const amount = ethers.utils.parseEther("0.2");
      const l2Chain = state.chains!.l2.find((c) => c.chainId === L2A_CHAIN_ID)!;

      // For gateway-settled chains, L1AssetTracker tracks balances under GW chain ID.
      const l1ChainBalanceBefore = await tracker.getL1ChainBalance(GW_CHAIN_ID, assetId);

      // Execute withdrawal
      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: L2A_CHAIN_ID,
        l1Addresses: state.l1Addresses!,
        amount,
      });

      expect(result.l2TxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

      const l1ChainBalanceAfter = await tracker.getL1ChainBalance(GW_CHAIN_ID, assetId);

      // Verify L1AssetTracker.chainBalance[GW] decreased
      const l1ChainBalanceDelta = l1ChainBalanceBefore.sub(l1ChainBalanceAfter);
      expect(
        l1ChainBalanceDelta.eq(amount),
        `L1AssetTracker.chainBalance[${GW_CHAIN_ID}] should decrease by ${amount.toString()}, got ${l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      console.log(`   L1AssetTracker.chainBalance[${GW_CHAIN_ID}]: ${l1ChainBalanceAfter.toString()}`);
    });
  });

  describe("processLogsAndMessages on GW for L2A withdrawal", () => {
    it("processes a withdrawal log and decreases GWAssetTracker.chainBalance", async () => {
      const gwChain = state.chains!.l2.find((c) => c.chainId === GW_CHAIN_ID)!;
      const gwProvider = new ethers.providers.JsonRpcProvider(gwChain.rpcUrl);

      // Use the canonical ETH asset ID (computed with L2_NTV_ADDR, not L1NTV)
      const assetId = encodeNtvAssetId(L1_CHAIN_ID, ETH_TOKEN_ADDRESS);
      const withdrawalAmount = ethers.utils.parseEther("0.1");
      const wallet = "0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266";

      // Establish GWAssetTracker.chainBalance[12] via the full Token Balance Migration flow:
      // L2 initiateL1ToGatewayMigrationOnL2 -> L1 receiveL1ToGatewayMigrationOnL1 -> GW confirmMigrationOnGateway
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const l2Chain = state.chains!.l2.find((c) => c.chainId === L2A_CHAIN_ID)!;
      const l2Provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);
      const gwDiamondProxy = state.chainAddresses!.find((c) => c.chainId === GW_CHAIN_ID)!.diamondProxy;
      const l2DiamondProxy = state.chainAddresses!.find((c) => c.chainId === L2A_CHAIN_ID)!.diamondProxy;

      await migrateTokenBalanceToGW({
        l2Provider,
        l1Provider,
        gwProvider,
        chainId: L2A_CHAIN_ID,
        assetId,
        l1AssetTrackerAddr: state.l1Addresses!.l1AssetTracker,
        gwDiamondProxyAddr: gwDiamondProxy,
        l2DiamondProxyAddr: l2DiamondProxy,
        logger: (line) => console.log(line),
      });

      // Snapshot GW chain balance before
      const gwBalanceBefore = await getGWChainBalance(gwProvider, L2A_CHAIN_ID, assetId);
      console.log(`   GWAssetTracker.chainBalance[${L2A_CHAIN_ID}] before: ${gwBalanceBefore.toString()}`);

      // Build the withdrawal log (AssetRouter message: L2A -> L1)
      const { log: withdrawalLog, message } = buildAssetRouterWithdrawalLog({
        txNumberInBatch: 0,
        assetId,
        amount: withdrawalAmount,
        receiver: wallet,
        originToken: ETH_TOKEN_ADDRESS,
        originalCaller: wallet,
        tokenOriginChainId: L1_CHAIN_ID,
      });

      // Call processLogsAndMessages on GW for chain L2A
      const result = await callProcessLogsAndMessages({
        gwProvider,
        gwRpcUrl: gwChain.rpcUrl,
        chainId: L2A_CHAIN_ID,
        logs: [withdrawalLog],
        messages: [message],
        logger: (line) => console.log(line),
      });

      expect(result.txHash).to.match(/^0x[0-9a-fA-F]{64}$/);

      // Snapshot GW chain balance after
      const gwBalanceAfter = await getGWChainBalance(gwProvider, L2A_CHAIN_ID, assetId);
      console.log(`   GWAssetTracker.chainBalance[${L2A_CHAIN_ID}] after: ${gwBalanceAfter.toString()}`);

      // Verify chainBalance decreased by withdrawal amount
      // _handleAssetRouterMessage -> _handleAssetRouterMessageInner(source=L2A, dest=L1)
      // -> _handleChainBalanceChangeOnGateway: decrements chainBalance[L2A] (since L2A != L1)
      const gwBalanceDelta = gwBalanceBefore.sub(gwBalanceAfter);
      expect(
        gwBalanceDelta.eq(withdrawalAmount),
        `GWAssetTracker.chainBalance[${L2A_CHAIN_ID}] should decrease by ${withdrawalAmount.toString()}, got ${gwBalanceDelta.toString()}`
      ).to.equal(true);
    });
  });
});

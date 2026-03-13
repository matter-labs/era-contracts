import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { createBalanceTrackerFromState, queryEthAssetId, computeBalanceDeltas } from "../../src/helpers/balance-tracker";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import { ANVIL_DEFAULT_ACCOUNT_ADDR } from "../../src/core/const";
import { getL2Chain, getChainDiamondProxy, getChainIdByRole } from "../../src/core/utils";

describe("02 - Direct L1<->L2 Bridge (direct-settled chain)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let directSettledChainId: number;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");
  });

  describe("ETH deposits L1 -> L2", () => {
    it("deposits ETH from L1 to L2", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const walletAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const amount = ethers.utils.parseEther("1.0");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);
      const chainDiamondProxy = getChainDiamondProxy(state.chainAddresses!, directSettledChainId);

      const before = await tracker.takeSnapshot(
        directSettledChainId,
        assetId,
        undefined, // ETH, not ERC20
        undefined,
        walletAddr,
        false
      );

      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1DiamondProxy: chainDiamondProxy,
      });

      expect(result.l1TxHash).to.not.be.null;

      const after = await tracker.takeSnapshot(directSettledChainId, assetId, undefined, undefined, walletAddr, false);

      const deltas = computeBalanceDeltas(before, after);
      expect(
        deltas.l1ChainBalanceDelta.eq(result.mintValue),
        `L1AssetTracker.chainBalance should increase by ${result.mintValue.toString()}, got ${deltas.l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      console.log(
        `   L1AssetTracker.chainBalance[${directSettledChainId}]: ${BigNumber.from(after.l1ChainBalance).toString()}`
      );
    });
  });

  describe("ETH withdrawals L2 -> L1", () => {
    it("withdraws ETH from L2 to L1", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const walletAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const amount = ethers.utils.parseEther("0.5");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);

      const before = await tracker.takeSnapshot(directSettledChainId, assetId, undefined, undefined, walletAddr, false);

      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
      });

      expect(result.l2TxHash).to.not.be.null;

      const after = await tracker.takeSnapshot(directSettledChainId, assetId, undefined, undefined, walletAddr, false);

      const deltas = computeBalanceDeltas(before, after);
      // Chain balance should decrease (delta is negative)
      expect(
        deltas.l1ChainBalanceDelta.eq(amount.mul(-1)),
        `L1AssetTracker.chainBalance should decrease by ${amount.toString()}, got ${deltas.l1ChainBalanceDelta.toString()}`
      ).to.equal(true);
    });
  });

  describe("Balance conservation", () => {
    it("L1AssetTracker chain balances equal total deposits minus withdrawals", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);

      // Check direct-settled chain: we deposited 1 ETH + gas and withdrew 0.5 ETH
      // The chain balance should reflect the net (deposit mintValue - withdrawal amount)
      const chainBalance = await tracker.getL1ChainBalance(directSettledChainId, assetId);
      expect(chainBalance.gt(0), "Direct-settled chain should have positive chain balance after deposit").to.equal(
        true
      );

      // Verify total across all chains is positive
      let totalChainBalance = BigNumber.from(0);
      for (const chainConfig of state.chains!.config) {
        if (!chainConfig.isL1) {
          const balance = await tracker.getL1ChainBalance(chainConfig.chainId, assetId);
          totalChainBalance = totalChainBalance.add(balance);
        }
      }
      expect(
        totalChainBalance.gt(0),
        "Total chain balance should be > 0 (we've deposited more than withdrawn)"
      ).to.equal(true);
      console.log(`   Total L1AssetTracker chain balance (ETH): ${ethers.utils.formatEther(totalChainBalance)}`);
    });
  });
});

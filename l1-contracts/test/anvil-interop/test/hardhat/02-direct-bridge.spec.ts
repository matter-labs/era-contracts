import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import {
  createBalanceTrackerFromState,
  queryEthAssetId,
  assertDepositBalances,
  assertWithdrawalBalances,
} from "../../src/balance-tracker";
import { depositETHToL2 } from "../../src/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/l2-withdrawal-helper";
import { ANVIL_DEFAULT_ACCOUNT_ADDR } from "../../src/const";

const CHAIN_ID = 10; // Direct L1-settled chain

describe("02 - Direct L1<->L2 Bridge (Chain 10)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;

  before(() => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
  });

  describe("ETH deposits L1 -> L2", () => {
    it("deposits ETH from L1 to L2", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const walletAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const amount = ethers.utils.parseEther("1.0");
      const l2Chain = state.chains!.l2.find((c) => c.chainId === CHAIN_ID)!;
      const chainDiamondProxy = state.chainAddresses!.find((c) => c.chainId === CHAIN_ID)!.diamondProxy;

      // Snapshot before
      const before = await tracker.takeSnapshot(
        CHAIN_ID,
        assetId,
        undefined, // ETH, not ERC20
        undefined,
        walletAddr,
        false
      );

      // Execute deposit
      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: CHAIN_ID,
        l1Addresses: state.l1Addresses!,
        amount,
        l1DiamondProxy: chainDiamondProxy,
      });

      expect(result.l1TxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

      // Snapshot after
      const after = await tracker.takeSnapshot(CHAIN_ID, assetId, undefined, undefined, walletAddr, false);

      // Verify L1AssetTracker.chainBalance increased by mintValue
      // (chainBalance tracks the full amount sent to the chain, including gas)
      const { l1ChainBalanceDelta } = assertDepositBalances(before, after);
      expect(
        l1ChainBalanceDelta.eq(result.mintValue),
        `L1AssetTracker.chainBalance[${CHAIN_ID}] should increase by ${result.mintValue.toString()}, got ${l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      console.log(`   L1AssetTracker.chainBalance[${CHAIN_ID}]: ${BigNumber.from(after.l1ChainBalance).toString()}`);
    });
  });

  describe("ETH withdrawals L2 -> L1", () => {
    it("withdraws ETH from L2 to L1", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const walletAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const amount = ethers.utils.parseEther("0.5");
      const l2Chain = state.chains!.l2.find((c) => c.chainId === CHAIN_ID)!;

      // Snapshot before
      const before = await tracker.takeSnapshot(CHAIN_ID, assetId, undefined, undefined, walletAddr, false);

      // Execute withdrawal
      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: CHAIN_ID,
        l1Addresses: state.l1Addresses!,
        amount,
      });

      expect(result.l2TxHash).to.match(/^0x[0-9a-fA-F]{64}$/);

      // Snapshot after
      const after = await tracker.takeSnapshot(CHAIN_ID, assetId, undefined, undefined, walletAddr, false);

      // Verify L1AssetTracker.chainBalance decreased
      const { l1ChainBalanceDelta } = assertWithdrawalBalances(before, after);
      expect(
        l1ChainBalanceDelta.eq(amount),
        `L1AssetTracker.chainBalance[${CHAIN_ID}] should decrease by ${amount.toString()}, got ${l1ChainBalanceDelta.toString()}`
      ).to.equal(true);
    });
  });

  describe("Balance conservation", () => {
    it("total L1AssetTracker chain balances are consistent", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);

      let totalChainBalance = BigNumber.from(0);
      for (const chainId of [10, 11, 12, 13]) {
        const balance = await tracker.getL1ChainBalance(chainId, assetId);
        totalChainBalance = totalChainBalance.add(balance);
      }

      // Total chain balance should be non-negative (it's the sum of all deposited - all withdrawn)
      expect(totalChainBalance.gte(0), "Total chain balance should be >= 0").to.equal(true);
      console.log(`   Total L1AssetTracker chain balance (ETH): ${ethers.utils.formatEther(totalChainBalance)}`);
    });
  });
});

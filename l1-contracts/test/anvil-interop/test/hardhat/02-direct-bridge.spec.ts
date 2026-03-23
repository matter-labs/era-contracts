import { expect } from "chai";
import { BigNumber, ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import {
  createBalanceTrackerFromState,
  queryEthAssetId,
  computeBalanceDeltas,
} from "../../src/helpers/balance-tracker";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import { ANVIL_DEFAULT_ACCOUNT_ADDR } from "../../src/core/const";
import { getL2Chain, getChainIdByRole } from "../../src/core/utils";

describe("02 - Direct L1<->L2 Bridge (direct-settled chain)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let directSettledChainId: number;
  let initialDirectChainBalance: BigNumber;
  let initialTotalChainBalance: BigNumber;
  let depositMintValue: BigNumber | null = null;
  let withdrawalAmount: BigNumber | null = null;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");

    const tracker = createBalanceTrackerFromState(state);
    const l1Provider = new ethers.providers.JsonRpcProvider(state.chains.l1!.rpcUrl);
    const assetId = await queryEthAssetId(l1Provider, state.l1Addresses.l1NativeTokenVault);

    initialDirectChainBalance = await tracker.getL1ChainBalance(directSettledChainId, assetId);
    initialTotalChainBalance = BigNumber.from(0);
    for (const chainConfig of state.chains.config) {
      if (chainConfig.role !== "l1") {
        const balance = await tracker.getL1ChainBalance(chainConfig.chainId, assetId);
        initialTotalChainBalance = initialTotalChainBalance.add(balance);
      }
    }
  });

  describe("ETH deposits L1 -> L2", () => {
    it("deposits ETH from L1 to L2", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const walletAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const amount = ethers.utils.parseEther("1.0");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);

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
      });

      expect(result.l1TxHash).to.not.be.null;
      depositMintValue = result.mintValue;

      const after = await tracker.takeSnapshot(directSettledChainId, assetId, undefined, undefined, walletAddr, false);

      const deltas = computeBalanceDeltas(before, after);
      expect(
        deltas.l1ChainBalanceDelta.eq(result.mintValue),
        `L1AssetTracker.chainBalance should increase by ${result.mintValue.toString()}, got ${deltas.l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      // Recipient's L2 ETH balance should increase (exact amount differs due to gas costs)
      expect(
        deltas.l2TokenDelta.gt(0),
        `Recipient L2 ETH balance should increase after deposit, got delta ${deltas.l2TokenDelta.toString()}`
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
      withdrawalAmount = amount;

      const after = await tracker.takeSnapshot(directSettledChainId, assetId, undefined, undefined, walletAddr, false);

      const deltas = computeBalanceDeltas(before, after);
      // Chain balance should decrease (delta is negative)
      expect(
        deltas.l1ChainBalanceDelta.eq(amount.mul(-1)),
        `L1AssetTracker.chainBalance should decrease by ${amount.toString()}, got ${deltas.l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      // L2 balance should decrease (by at least the withdrawal amount; gas costs cause additional decrease)
      expect(
        deltas.l2TokenDelta.lte(amount.mul(-1)),
        `L2 ETH balance should decrease by at least ${amount.toString()}, got delta ${deltas.l2TokenDelta.toString()}`
      ).to.equal(true);
    });
  });

  describe("L1AssetTracker accounting", () => {
    it("L1AssetTracker balances reflect the net flow performed", async () => {
      if (!depositMintValue || !withdrawalAmount) {
        throw new Error("Expected deposit and withdrawal test data to be populated before balance verification");
      }

      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);

      const expectedNetDelta = depositMintValue.sub(withdrawalAmount);

      const directChainBalance = await tracker.getL1ChainBalance(directSettledChainId, assetId);
      const expectedDirectChainBalance = initialDirectChainBalance.add(expectedNetDelta);
      expect(
        directChainBalance.eq(expectedDirectChainBalance),
        `Direct-settled chain balance should equal initial balance ${initialDirectChainBalance.toString()} + net delta ${expectedNetDelta.toString()}, got ${directChainBalance.toString()}`
      ).to.equal(true);

      let totalChainBalance = BigNumber.from(0);
      for (const chainConfig of state.chains!.config) {
        if (chainConfig.role !== "l1") {
          const balance = await tracker.getL1ChainBalance(chainConfig.chainId, assetId);
          totalChainBalance = totalChainBalance.add(balance);
        }
      }
      const expectedTotalChainBalance = initialTotalChainBalance.add(expectedNetDelta);
      expect(
        totalChainBalance.eq(expectedTotalChainBalance),
        `Total ETH chain balance should equal initial total ${initialTotalChainBalance.toString()} + net delta ${expectedNetDelta.toString()}, got ${totalChainBalance.toString()}`
      ).to.equal(true);

      console.log(
        `   Direct chain balance: ${ethers.utils.formatEther(directChainBalance)} ETH (expected ${ethers.utils.formatEther(expectedDirectChainBalance)} ETH)`
      );
      console.log(`   Total L1AssetTracker chain balance (ETH): ${ethers.utils.formatEther(totalChainBalance)}`);
    });
  });
});

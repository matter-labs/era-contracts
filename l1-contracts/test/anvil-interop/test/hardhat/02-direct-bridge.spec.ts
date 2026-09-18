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
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_RECIPIENT_ADDR } from "../../src/core/const";
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
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = ethers.utils.parseEther("1.0");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);

      // Snapshot sender's L1 balance and recipient's L2 balance separately
      const senderBefore = await tracker.takeSnapshot(
        directSettledChainId,
        assetId,
        undefined,
        undefined,
        senderAddr,
        false
      );
      const recipientL2Before = await tracker.getL2EthBalance(directSettledChainId, recipientAddr);

      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        recipient: recipientAddr,
      });

      expect(result.l1TxHash).to.not.be.null;
      depositMintValue = result.mintValue;

      const senderAfter = await tracker.takeSnapshot(
        directSettledChainId,
        assetId,
        undefined,
        undefined,
        senderAddr,
        false
      );
      const recipientL2After = await tracker.getL2EthBalance(directSettledChainId, recipientAddr);

      const deltas = computeBalanceDeltas(senderBefore, senderAfter);

      // L1AssetTracker.chainBalance should increase by mintValue
      expect(
        deltas.l1ChainBalanceDelta.eq(result.mintValue),
        `L1AssetTracker.chainBalance should increase by ${result.mintValue.toString()}, got ${deltas.l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      // Sender's L1 ETH balance should decrease (by at least mintValue; gas costs add to the decrease)
      expect(
        deltas.l1TokenDelta.lte(result.mintValue.mul(-1)),
        `Sender L1 ETH balance should decrease by at least ${result.mintValue.toString()}, got delta ${deltas.l1TokenDelta.toString()}`
      ).to.equal(true);

      // Recipient's L2 ETH balance should increase
      const recipientL2Delta = recipientL2After.sub(recipientL2Before);
      expect(
        recipientL2Delta.gt(0),
        `Recipient L2 ETH balance should increase after deposit, got delta ${recipientL2Delta.toString()}`
      ).to.equal(true);

      console.log(
        `   L1AssetTracker.chainBalance[${directSettledChainId}]: ${BigNumber.from(senderAfter.l1ChainBalance).toString()}`
      );
      console.log(`   Recipient L2 ETH balance delta: ${ethers.utils.formatEther(recipientL2Delta)} ETH`);
    });
  });

  describe("ETH withdrawals L2 -> L1", () => {
    it("withdraws ETH from L2 to L1", async () => {
      const tracker = createBalanceTrackerFromState(state);
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const assetId = await queryEthAssetId(l1Provider, state.l1Addresses!.l1NativeTokenVault);
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = ethers.utils.parseEther("0.5");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);

      // Snapshot sender's L2 balance and recipient's L1 balance separately
      const senderBefore = await tracker.takeSnapshot(
        directSettledChainId,
        assetId,
        undefined,
        undefined,
        senderAddr,
        false
      );
      const recipientL1Before = await tracker.getL1EthBalance(recipientAddr);

      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1Recipient: recipientAddr,
      });

      expect(result.l2TxHash).to.not.be.null;
      withdrawalAmount = amount;

      const senderAfter = await tracker.takeSnapshot(
        directSettledChainId,
        assetId,
        undefined,
        undefined,
        senderAddr,
        false
      );
      const recipientL1After = await tracker.getL1EthBalance(recipientAddr);

      const deltas = computeBalanceDeltas(senderBefore, senderAfter);

      // L1AssetTracker.chainBalance should decrease by the withdrawal amount
      expect(
        deltas.l1ChainBalanceDelta.eq(amount.mul(-1)),
        `L1AssetTracker.chainBalance should decrease by ${amount.toString()}, got ${deltas.l1ChainBalanceDelta.toString()}`
      ).to.equal(true);

      // Recipient's L1 ETH balance should increase by exactly the withdrawal amount
      const recipientL1Delta = recipientL1After.sub(recipientL1Before);
      expect(
        recipientL1Delta.eq(amount),
        `Recipient L1 ETH balance should increase by ${amount.toString()}, got delta ${recipientL1Delta.toString()}`
      ).to.equal(true);

      console.log(`   Recipient L1 ETH balance delta: ${ethers.utils.formatEther(recipientL1Delta)} ETH`);
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

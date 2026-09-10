import { expect } from "chai";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import { getL1BridgedOut, getL1BaseTokenAssetId } from "../../src/helpers/bridged-out-helper";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_RECIPIENT_ADDR } from "../../src/core/const";
import { getL2Chain, getChainIdByRole } from "../../src/core/utils";

describe("02 - Direct L1<->L2 Bridge (direct-settled chain)", function () {
  this.timeout(0);

  const runner = new DeploymentRunner();
  let state: ReturnType<typeof runner.loadState>;
  let directSettledChainId: number;

  before(async () => {
    state = runner.loadState();
    if (!state.chains || !state.l1Addresses || !state.chainAddresses) {
      throw new Error("Deployment state incomplete. Run setup first.");
    }
    directSettledChainId = getChainIdByRole(state.chains.config, "directSettled");
  });

  describe("ETH deposits L1 -> L2", () => {
    it("deposits ETH from L1 to L2", async () => {
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = ethers.utils.parseEther("1.0");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);
      const l2Provider = new ethers.providers.JsonRpcProvider(l2Chain.rpcUrl);

      // Snapshot sender's L1 balance and recipient's L2 balance separately
      const senderL1Before = await l1Provider.getBalance(senderAddr);
      const recipientL2Before = await l2Provider.getBalance(recipientAddr);

      // Snapshot L1NativeTokenVault.bridgedOut[ETH]
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(state.chains!.l1!.rpcUrl, l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);

      const result = await depositETHToL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        recipient: recipientAddr,
      });

      expect(result.l1TxHash).to.not.be.null;

      const senderL1After = await l1Provider.getBalance(senderAddr);
      const recipientL2After = await l2Provider.getBalance(recipientAddr);

      // L1NativeTokenVault.bridgedOut[ETH] should increase by exactly the bridged amount (mintValue).
      const bridgedOutAfter = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);
      const bridgedOutDelta = bridgedOutAfter.sub(bridgedOutBefore);
      expect(
        bridgedOutDelta.eq(result.mintValue),
        `bridgedOut[ETH] should increase by ${result.mintValue.toString()}, got ${bridgedOutDelta.toString()}`
      ).to.equal(true);

      // Sender's L1 ETH balance should decrease (by at least mintValue; gas costs add to the decrease)
      const senderL1Delta = senderL1After.sub(senderL1Before);
      expect(
        senderL1Delta.lte(result.mintValue.mul(-1)),
        `Sender L1 ETH balance should decrease by at least ${result.mintValue.toString()}, got delta ${senderL1Delta.toString()}`
      ).to.equal(true);

      // Recipient's L2 ETH balance should increase
      const recipientL2Delta = recipientL2After.sub(recipientL2Before);
      expect(
        recipientL2Delta.gt(0),
        `Recipient L2 ETH balance should increase after deposit, got delta ${recipientL2Delta.toString()}`
      ).to.equal(true);

      console.log(`   Recipient L2 ETH balance delta: ${ethers.utils.formatEther(recipientL2Delta)} ETH`);
    });
  });

  describe("ETH withdrawals L2 -> L1", () => {
    it("withdraws ETH from L2 to L1", async () => {
      const l1Provider = new ethers.providers.JsonRpcProvider(state.chains!.l1!.rpcUrl);
      const recipientAddr = ANVIL_RECIPIENT_ADDR;
      const amount = ethers.utils.parseEther("0.5");
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);

      // Snapshot recipient's L1 balance
      const recipientL1Before = await l1Provider.getBalance(recipientAddr);

      // Snapshot L1NativeTokenVault.bridgedOut[ETH] before finalizing the withdrawal on L1.
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const ethAssetId = await getL1BaseTokenAssetId(state.chains!.l1!.rpcUrl, l1Ntv);
      const bridgedOutBefore = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);

      const result = await withdrawETHFromL2({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1Recipient: recipientAddr,
      });

      expect(result.l2TxHash).to.not.be.null;

      const recipientL1After = await l1Provider.getBalance(recipientAddr);

      // L1NativeTokenVault.bridgedOut[ETH] should decrease by exactly the withdrawn amount.
      const bridgedOutAfter = await getL1BridgedOut(state.chains!.l1!.rpcUrl, l1Ntv, ethAssetId);
      const bridgedOutDelta = bridgedOutBefore.sub(bridgedOutAfter);
      expect(
        bridgedOutDelta.eq(amount),
        `bridgedOut[ETH] should decrease by ${amount.toString()}, got ${bridgedOutDelta.toString()}`
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
});

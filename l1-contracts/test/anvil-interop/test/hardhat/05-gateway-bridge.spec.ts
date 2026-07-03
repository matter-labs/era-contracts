import { expect } from "chai";
import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { depositETHToL2 } from "../../src/helpers/l1-deposit-helper";
import { withdrawETHFromL2 } from "../../src/helpers/l2-withdrawal-helper";
import { ANVIL_DEFAULT_ACCOUNT_ADDR, ANVIL_RECIPIENT_ADDR } from "../../src/core/const";
import { getL1RpcUrl, getL2RpcUrl, getChainIdByRole, getChainIdsByRole } from "../../src/core/utils";

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
      const l1Provider = new ethers.providers.JsonRpcProvider(getL1RpcUrl(state));
      const amount = ethers.utils.parseEther("0.5");
      const senderAddr = ANVIL_DEFAULT_ACCOUNT_ADDR;

      const senderL1Before = await l1Provider.getBalance(senderAddr);

      const result = await depositETHToL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        gwRpcUrl: getL2RpcUrl(state, gwChainId),
      });

      expect(result.l1TxHash).to.not.be.null;

      const senderL1After = await l1Provider.getBalance(senderAddr);

      // Sender's L1 ETH balance should decrease (by at least mintValue; gas adds to the decrease)
      const senderL1Delta = senderL1After.sub(senderL1Before);
      expect(
        senderL1Delta.lte(result.mintValue.mul(-1)),
        `Sender L1 ETH should decrease by at least ${result.mintValue.toString()}, got delta ${senderL1Delta.toString()}`
      ).to.equal(true);
    });
  });

  describe("ETH withdrawals GW-settled chain -> L1 through gateway", () => {
    it("withdraws ETH from GW-settled chain to L1", async () => {
      const l1Provider = new ethers.providers.JsonRpcProvider(getL1RpcUrl(state));
      const amount = ethers.utils.parseEther("0.2");
      const recipientAddr = ANVIL_RECIPIENT_ADDR;

      const recipientL1Before = await l1Provider.getBalance(recipientAddr);

      const result = await withdrawETHFromL2({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1Recipient: recipientAddr,
      });

      expect(result.l2TxHash).to.not.be.null;

      const recipientL1After = await l1Provider.getBalance(recipientAddr);

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

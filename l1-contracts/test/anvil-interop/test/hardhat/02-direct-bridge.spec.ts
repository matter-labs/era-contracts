import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { expectEthDeposit } from "../../src/helpers/l1-deposit-helper";
import { expectEthWithdrawal } from "../../src/helpers/l2-withdrawal-helper";
import { ANVIL_RECIPIENT_ADDR } from "../../src/core/const";
import { getL2Chain, getChainIdByRole } from "../../src/core/utils";
import { randomBigNumber } from "../../src/helpers/balance-helpers";

const ETH_AMOUNT_MIN = ethers.utils.parseEther("0.1");
const ETH_AMOUNT_MAX = ethers.utils.parseEther("0.5");

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
      await expectEthDeposit({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: getL2Chain(state.chains!, directSettledChainId).rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount: randomBigNumber(ETH_AMOUNT_MIN, ETH_AMOUNT_MAX),
        recipient: ANVIL_RECIPIENT_ADDR,
      });
    });
  });

  describe("ETH withdrawals L2 -> L1", () => {
    it("withdraws ETH from L2 to L1", async () => {
      await expectEthWithdrawal({
        l1RpcUrl: state.chains!.l1!.rpcUrl,
        l2RpcUrl: getL2Chain(state.chains!, directSettledChainId).rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount: randomBigNumber(ETH_AMOUNT_MIN, ETH_AMOUNT_MAX),
        l1Recipient: ANVIL_RECIPIENT_ADDR,
      });
    });
  });
});

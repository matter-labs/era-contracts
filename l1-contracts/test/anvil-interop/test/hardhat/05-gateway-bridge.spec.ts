import { ethers } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { expectEthDeposit } from "../../src/helpers/l1-deposit-helper";
import { expectEthWithdrawal } from "../../src/helpers/l2-withdrawal-helper";
import { ANVIL_RECIPIENT_ADDR } from "../../src/core/const";
import { getL1RpcUrl, getL2RpcUrl, getChainIdByRole, getChainIdsByRole } from "../../src/core/utils";
import { randomBigNumber } from "../../src/helpers/balance-helpers";

// The GW-settled chain has no interop, so L1 caps its withdrawals at what was deposited into it
// ({protocol-docs/interop-gating.md#per-chain-balance-cap}): the withdrawal stays below the deposit.
const DEPOSIT_AMOUNT_MIN = ethers.utils.parseEther("0.5");
const DEPOSIT_AMOUNT_MAX = ethers.utils.parseEther("1");
const WITHDRAWAL_AMOUNT_MIN = ethers.utils.parseEther("0.1");
const WITHDRAWAL_AMOUNT_MAX = ethers.utils.parseEther("0.5");

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
      await expectEthDeposit({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount: randomBigNumber(DEPOSIT_AMOUNT_MIN, DEPOSIT_AMOUNT_MAX),
        recipient: ANVIL_RECIPIENT_ADDR,
        gwRpcUrl: getL2RpcUrl(state, gwChainId),
      });
    });
  });

  describe("ETH withdrawals GW-settled chain -> L1 through gateway", () => {
    it("withdraws ETH from GW-settled chain to L1", async () => {
      await expectEthWithdrawal({
        l1RpcUrl: getL1RpcUrl(state),
        l2RpcUrl: getL2RpcUrl(state, gwSettledChainId),
        chainId: gwSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount: randomBigNumber(WITHDRAWAL_AMOUNT_MIN, WITHDRAWAL_AMOUNT_MAX),
        l1Recipient: ANVIL_RECIPIENT_ADDR,
      });
    });
  });
});

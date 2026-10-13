import { expect } from "chai";
import type { Contract } from "ethers";
import { ContractFactory, ethers, Wallet } from "ethers";
import { DeploymentRunner } from "../../src/deployment-runner";
import { depositERC20ToL2, expectEthDeposit } from "../../src/helpers/l1-deposit-helper";
import {
  expectEthWithdrawal,
  finalizeWithdrawalOnL1,
  initiateErc20Withdrawal,
} from "../../src/helpers/l2-withdrawal-helper";
import { getL1BridgedOut } from "../../src/helpers/bridged-out-helper";
import { getTokenAddressForAsset, getTokenBalance, randomBigNumber } from "../../src/helpers/balance-helpers";
import {
  ANVIL_DEFAULT_ACCOUNT_ADDR,
  ANVIL_DEFAULT_PRIVATE_KEY,
  ANVIL_RECIPIENT_ADDR,
  TEST_TOKEN_DECIMALS,
} from "../../src/core/const";
import { getInteropSourceAddress } from "../../src/core/accounts";
import { getAbi, getCreationBytecode } from "../../src/core/contracts";
import { getL2Chain, getChainIdByRole, createProvider } from "../../src/core/utils";

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

  describe("ERC20 round trip L1 -> L2 -> L1", () => {
    it("deposits an L1-native ERC20 to L2 and withdraws it back to L1", async () => {
      const l1RpcUrl = state.chains!.l1!.rpcUrl;
      const l1Provider = createProvider(l1RpcUrl);
      const l2Chain = getL2Chain(state.chains!, directSettledChainId);
      const l2Provider = createProvider(l2Chain.rpcUrl);
      const l1Ntv = state.l1Addresses!.l1NativeTokenVault;
      const amount = ethers.utils.parseUnits("10", TEST_TOKEN_DECIMALS);

      // A fresh token, so its vault balance and bridgedOut start at zero.
      const factory = new ContractFactory(
        getAbi("TestnetERC20Token"),
        getCreationBytecode("TestnetERC20Token"),
        new Wallet(ANVIL_DEFAULT_PRIVATE_KEY, l1Provider)
      );
      const l1Token: Contract = await factory.deploy("Round Trip Token", "RTT", TEST_TOKEN_DECIMALS);
      await l1Token.deployed();
      await (await l1Token.mint(ANVIL_DEFAULT_ACCOUNT_ADDR, amount)).wait();

      // `depositERC20ToL2` pays from the default account; credit the account the withdrawal is sent from.
      const l2Holder = getInteropSourceAddress();
      const deposit = await depositERC20ToL2({
        l1RpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        tokenAddress: l1Token.address,
        amount,
        recipient: l2Holder,
      });

      const l2TokenAddress = await getTokenAddressForAsset(l2Provider, deposit.assetId);
      expect(l2TokenAddress, "L2 NTV should deploy the bridged token on deposit").to.not.equal(
        ethers.constants.AddressZero
      );
      const l2BalanceAfterDeposit = await getTokenBalance(l2Provider, l2TokenAddress, l2Holder);
      expect(l2BalanceAfterDeposit.eq(amount), `L2 balance should be ${amount}, got ${l2BalanceAfterDeposit}`).to.equal(
        true
      );
      const lockedAfterDeposit: ethers.BigNumber = await l1Token.balanceOf(l1Ntv);
      expect(lockedAfterDeposit.eq(amount), `L1 NTV should lock ${amount}, got ${lockedAfterDeposit}`).to.equal(true);
      const bridgedOutAfterDeposit = await getL1BridgedOut(l1RpcUrl, l1Ntv, deposit.assetId);
      expect(
        bridgedOutAfterDeposit.eq(amount),
        `bridgedOut should be ${amount} after the deposit, got ${bridgedOutAfterDeposit}`
      ).to.equal(true);

      const pending = await initiateErc20Withdrawal({
        l1RpcUrl,
        l2RpcUrl: l2Chain.rpcUrl,
        chainId: directSettledChainId,
        l1Addresses: state.l1Addresses!,
        amount,
        l1Recipient: ANVIL_RECIPIENT_ADDR,
        l2TokenAddress,
      });

      const l2BalanceAfterWithdrawal = await getTokenBalance(l2Provider, l2TokenAddress, l2Holder);
      expect(
        l2BalanceAfterWithdrawal.isZero(),
        `L2 balance should be burned, got ${l2BalanceAfterWithdrawal}`
      ).to.equal(true);

      const result = await finalizeWithdrawalOnL1(l1RpcUrl, state.l1Addresses!, pending);
      expect(result.success, `L1 finalization failed: ${result.errorMessage}`).to.equal(true);

      const recipientL1Balance: ethers.BigNumber = await l1Token.balanceOf(ANVIL_RECIPIENT_ADDR);
      expect(recipientL1Balance.eq(amount), `L1 recipient should get ${amount}, got ${recipientL1Balance}`).to.equal(
        true
      );
      const lockedAfterWithdrawal: ethers.BigNumber = await l1Token.balanceOf(l1Ntv);
      expect(lockedAfterWithdrawal.isZero(), `L1 NTV should release everything, got ${lockedAfterWithdrawal}`).to.equal(
        true
      );
      const bridgedOutAfterWithdrawal = await getL1BridgedOut(l1RpcUrl, l1Ntv, deposit.assetId);
      expect(
        bridgedOutAfterWithdrawal.isZero(),
        `bridgedOut should be back to zero, got ${bridgedOutAfterWithdrawal}`
      ).to.equal(true);
    });
  });
});

import type { L2EthToken, MockContract, MsgValueSimulator } from "../typechain";
import { L2EthTokenFactory, MsgValueSimulatorFactory } from "../typechain";
import { deployContract, deployContractOnAddress, getWallets, loadZasmBytecode, setCode } from "./shared/utils";
import {
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TEST_ETH_TOKEN_SYSTEM_CONTRACT_ADDRESS,
  TEST_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS,
} from "./shared/constants";
import { prepareEnvironment } from "./shared/mocks";
import { expect } from "chai";
import { EXTRA_ABI_CALLER_ADDRESS, encodeExtraAbiCallerCalldata } from "./shared/extraAbiCaller";
import { BigNumber } from "ethers";
import { Contract } from "zksync-web3";
import * as hardhat from "hardhat";

describe("New MsgValueSimulator tests", () => {
  let messageValueSimulator: MsgValueSimulator;
  let extraAbiCaller: Contract;
  let mockContract: MockContract;
  let l2EthToken: L2EthToken;
  const wallet = getWallets()[0];
  const msgSender = "0x000000000000000000000000000000000000beef";

  before(async () => {
    // Prepare environment
    await prepareEnvironment();
    await deployContractOnAddress(TEST_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS, "MsgValueSimulator");
    await deployContractOnAddress(TEST_ETH_TOKEN_SYSTEM_CONTRACT_ADDRESS, "L2EthToken");
    mockContract = (await deployContract("MockContract")) as MockContract;

    // Prepare MsgValueSimulator
    messageValueSimulator = MsgValueSimulatorFactory.connect(TEST_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS, wallet);
    const extraAbiCallerBytecode = await loadZasmBytecode("ExtraAbiCaller", "test-contracts");
    await setCode(EXTRA_ABI_CALLER_ADDRESS, extraAbiCallerBytecode);
    extraAbiCaller = new Contract(EXTRA_ABI_CALLER_ADDRESS, [], wallet);

    // Prepare ETH token
    l2EthToken = L2EthTokenFactory.connect(TEST_ETH_TOKEN_SYSTEM_CONTRACT_ADDRESS, wallet);

    // Mint some tokens to the wallet
    const bootloaderAccount = await hardhat.ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    await (await l2EthToken.connect(bootloaderAccount).mint(msgSender, BigNumber.from(2).pow(128))).wait();

    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
    });
  });

  it("send 1 ETH", async () => {
    // load state before execution
    const value = 1000000000000000000n;
    const balanceBefore = await l2EthToken.balanceOf(msgSender);
    const contractBalanceBefore = await l2EthToken.balanceOf(mockContract.address);

    // transfer 1 ETH to the contract
    // extraAbi -> messageValueSimulator -> mockContract
    await expect(
      extraAbiCaller.connect(wallet).fallback({
        data: encodeExtraAbiCallerCalldata(
          messageValueSimulator.address,
          BigNumber.from(0),
          [value.toString(), mockContract.address, "0"],
          "0x"
        ),
      })
    )
      .to.emit(mockContract, "Called")
      .withArgs(value, "0x");

    // check state after execution
    const balanceAfter = await l2EthToken.balanceOf(msgSender);
    expect(balanceBefore.sub(value)).to.equal(balanceAfter);
    const contractBalanceAfter = await l2EthToken.balanceOf(mockContract.address);
    expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  });

  it("send 0 ETH", async () => {
    const value = 0;
    const balanceBefore = await l2EthToken.balanceOf(msgSender);
    const contractBalanceBefore = await l2EthToken.balanceOf(mockContract.address);

    await expect(
      extraAbiCaller.fallback({
        data: encodeExtraAbiCallerCalldata(
          messageValueSimulator.address,
          BigNumber.from(0),
          [value.toString(), mockContract.address, "0"],
          "0x"
        ),
      })
    )
      .to.emit(mockContract, "Called")
      .withArgs(value, "0x");

    const balanceAfter = await l2EthToken.balanceOf(msgSender);
    expect(balanceBefore.sub(value)).to.equal(balanceAfter);
    const contractBalanceAfter = await l2EthToken.balanceOf(mockContract.address);
    expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  });

  it("send 1 wei", async () => {
    const value = 1;
    const balanceBefore = await l2EthToken.balanceOf(msgSender);
    const contractBalanceBefore = await l2EthToken.balanceOf(mockContract.address);

    await expect(
      extraAbiCaller.fallback({
        data: encodeExtraAbiCallerCalldata(
          messageValueSimulator.address,
          BigNumber.from(0),
          [value.toString(), mockContract.address, "0"],
          "0x"
        ),
      })
    )
      .to.emit(mockContract, "Called")
      .withArgs(value, "0x");

    const balanceAfter = await l2EthToken.balanceOf(msgSender);
    expect(balanceBefore.sub(value)).to.equal(balanceAfter);
    const contractBalanceAfter = await l2EthToken.balanceOf(mockContract.address);
    expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  });

  it("send 2^127 wei", async () => {
    const value = BigNumber.from(2).pow(127);
    const balanceBefore = await l2EthToken.balanceOf(msgSender);
    const contractBalanceBefore = await l2EthToken.balanceOf(mockContract.address);

    await expect(
      extraAbiCaller.fallback({
        data: encodeExtraAbiCallerCalldata(
          messageValueSimulator.address,
          BigNumber.from(0),
          [value.toString(), mockContract.address, "0"],
          "0x"
        ),
      })
    )
      .to.emit(mockContract, "Called")
      .withArgs(value, "0x");

    const balanceAfter = await l2EthToken.balanceOf(msgSender);
    expect(balanceBefore.sub(value)).to.equal(balanceAfter);
    const contractBalanceAfter = await l2EthToken.balanceOf(mockContract.address);
    expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  });

  it("revert with reentry", async () => {
    const balanceBefore = await l2EthToken.balanceOf(msgSender);
    const contractBalanceBefore = await l2EthToken.balanceOf(mockContract.address);

    await expect(
      extraAbiCaller.fallback({
        data: encodeExtraAbiCallerCalldata(
          messageValueSimulator.address,
          BigNumber.from(0),
          ["0x1", messageValueSimulator.address, "0"],
          "0x"
        ),
      })
    ).to.be.reverted;

    const balanceAfter = await l2EthToken.balanceOf(msgSender);
    expect(balanceBefore).to.equal(balanceAfter);

    const contractBalanceAfter = await l2EthToken.balanceOf(mockContract.address);
    expect(contractBalanceBefore).to.equal(contractBalanceAfter);
  });

  it("revert more than balance", async () => {
    const balanceBefore = await l2EthToken.balanceOf(msgSender);
    const contractBalanceBefore = await l2EthToken.balanceOf(mockContract.address);
    const value = balanceBefore.add(1);

    await expect(
      extraAbiCaller.fallback({
        data: encodeExtraAbiCallerCalldata(
          messageValueSimulator.address,
          BigNumber.from(0),
          [value.toString(), mockContract.address, "0"],
          "0x"
        ),
      })
    ).to.be.reverted;

    const balanceAfter = await l2EthToken.balanceOf(msgSender);
    expect(balanceBefore).to.equal(balanceAfter);

    const contractBalanceAfter = await l2EthToken.balanceOf(mockContract.address);
    expect(contractBalanceBefore).to.equal(contractBalanceAfter);
  });
});

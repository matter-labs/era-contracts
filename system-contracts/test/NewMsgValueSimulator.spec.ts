import type { L2BaseToken, MockContract, MsgValueSimulator } from "../typechain";
import { L2BaseTokenFactory, MsgValueSimulatorFactory } from "../typechain";
import {
  deployContract,
  deployContractOnAddress,
  getWallets,
  loadArtifact,
  loadZasmBytecode,
  setCode,
} from "./shared/utils";
import {
  REAL_BASE_TOKEN_SYSTEM_CONTRACT,
  REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS,
  TEST_BOOTLOADER_FORMAL_ADDRESS,
} from "./shared/constants";
import { prepareEnvironment } from "./shared/mocks";
import { expect } from "chai";
import { EXTRA_ABI_CALLER_ADDRESS, encodeExtraAbiCallerCalldata } from "./shared/extraAbiCaller";
import { BigNumber } from "ethers";
import { Contract } from "zksync-web3";
import * as hardhat from "hardhat";

describe("NewMsgValueSimulator tests", () => {
  let messageValueSimulator: MsgValueSimulator;
  let extraAbiCaller: Contract;
  let mockContract: MockContract;
  let L2BaseToken: L2BaseToken;
  const wallet = getWallets()[0];
  const msgSender = "0x000000000000000000000000000000000000beef";

  before(async () => {
    // Prepare environment
    await prepareEnvironment();
    await deployContractOnAddress(REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS, "MsgValueSimulator");
    await deployContractOnAddress(REAL_BASE_TOKEN_SYSTEM_CONTRACT, "L2BaseToken");

    // const testedMsgValueSimulatorCode = (await loadArtifact("MsgValueSimulator")).bytecode;
    // await setCode(REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS, testedMsgValueSimulatorCode);

    mockContract = (await deployContract("MockContract")) as MockContract;

    // // Prepare MsgValueSimulator
    // messageValueSimulator = MsgValueSimulatorFactory.connect(REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS, wallet);
    // const extraAbiCallerBytecode = await loadZasmBytecode("ExtraAbiCaller", "test-contracts");
    // await setCode(EXTRA_ABI_CALLER_ADDRESS, extraAbiCallerBytecode);
    // extraAbiCaller = new Contract(EXTRA_ABI_CALLER_ADDRESS, [], wallet);

    // // Prepare ETH token
    // L2BaseToken = L2BaseTokenFactory.connect(REAL_BASE_TOKEN_SYSTEM_CONTRACT, wallet);

    // // Mint some tokens to the wallet
    // const bootloaderAccount = await hardhat.ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    // await (await l2EthToken.connect(bootloaderAccount).mint(msgSender, BigNumber.from(2).pow(128))).wait();

    // await network.provider.request({
    //   method: "hardhat_stopImpersonatingAccount",
    //   params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
    // });
  });

  it("send 1 ETH", async () => {
    // load state before execution
    const value = 1000000000000000000n;
    const balanceBefore = await L2BaseToken.balanceOf(msgSender);
    const contractBalanceBefore = await L2BaseToken.balanceOf(mockContract.address);

    // transfer 1 ETH to the contract
    // extraAbi -> messageValueSimulator -> mockContract
    // await expect(
    //   extraAbiCaller.connect(wallet).fallback({
    //     data: encodeExtraAbiCallerCalldata(
    //       messageValueSimulator.address,
    //       BigNumber.from(0),
    //       [value.toString(), mockContract.address, "0"],
    //       "0x"
    //     ),
    //   })
    // )
    //   .to.emit(mockContract, "Called")
    //   .withArgs(value, "0x");

    await extraAbiCaller.connect(wallet).fallback({
      data: encodeExtraAbiCallerCalldata(
        messageValueSimulator.address,
        BigNumber.from(0),
        [value.toString(), mockContract.address, "0"],
        "0x"
      ),
    });

    // check state after execution
    const balanceAfter = await L2BaseToken.balanceOf(msgSender);
    expect(balanceBefore.sub(value)).to.equal(balanceAfter);
    const contractBalanceAfter = await L2BaseToken.balanceOf(mockContract.address);
    expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  });

  //   it("send 0 ETH", async () => {
  //     const value = 0;
  //     const balanceBefore = await L2BaseToken.balanceOf(msgSender);
  //     const contractBalanceBefore = await L2BaseToken.balanceOf(mockContract.address);

  //     await expect(
  //       extraAbiCaller.fallback({
  //         data: encodeExtraAbiCallerCalldata(
  //           messageValueSimulator.address,
  //           BigNumber.from(0),
  //           [value.toString(), mockContract.address, "0"],
  //           "0x"
  //         ),
  //       })
  //     )
  //       .to.emit(mockContract, "Called")
  //       .withArgs(value, "0x");

  //     const balanceAfter = await L2BaseToken.balanceOf(msgSender);
  //     expect(balanceBefore.sub(value)).to.equal(balanceAfter);
  //     const contractBalanceAfter = await L2BaseToken.balanceOf(mockContract.address);
  //     expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  //   });

  //   it("send 1 wei", async () => {
  //     const value = 1;
  //     const balanceBefore = await L2BaseToken.balanceOf(msgSender);
  //     const contractBalanceBefore = await L2BaseToken.balanceOf(mockContract.address);

  //     await expect(
  //       extraAbiCaller.fallback({
  //         data: encodeExtraAbiCallerCalldata(
  //           messageValueSimulator.address,
  //           BigNumber.from(0),
  //           [value.toString(), mockContract.address, "0"],
  //           "0x"
  //         ),
  //       })
  //     )
  //       .to.emit(mockContract, "Called")
  //       .withArgs(value, "0x");

  //     const balanceAfter = await L2BaseToken.balanceOf(msgSender);
  //     expect(balanceBefore.sub(value)).to.equal(balanceAfter);
  //     const contractBalanceAfter = await L2BaseToken.balanceOf(mockContract.address);
  //     expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  //   });

  //   it("send 2^127 wei", async () => {
  //     const value = BigNumber.from(2).pow(127);
  //     const balanceBefore = await L2BaseToken.balanceOf(msgSender);
  //     const contractBalanceBefore = await L2BaseToken.balanceOf(mockContract.address);

  //     await expect(
  //       extraAbiCaller.fallback({
  //         data: encodeExtraAbiCallerCalldata(
  //           messageValueSimulator.address,
  //           BigNumber.from(0),
  //           [value.toString(), mockContract.address, "0"],
  //           "0x"
  //         ),
  //       })
  //     )
  //       .to.emit(mockContract, "Called")
  //       .withArgs(value, "0x");

  //     const balanceAfter = await L2BaseToken.balanceOf(msgSender);
  //     expect(balanceBefore.sub(value)).to.equal(balanceAfter);
  //     const contractBalanceAfter = await L2BaseToken.balanceOf(mockContract.address);
  //     expect(contractBalanceBefore.add(value)).to.equal(contractBalanceAfter);
  //   });

  //   it("revert with reentry", async () => {
  //     const balanceBefore = await L2BaseToken.balanceOf(msgSender);
  //     const contractBalanceBefore = await L2BaseToken.balanceOf(mockContract.address);

  //     await expect(
  //       extraAbiCaller.fallback({
  //         data: encodeExtraAbiCallerCalldata(
  //           messageValueSimulator.address,
  //           BigNumber.from(0),
  //           ["0x1", messageValueSimulator.address, "0"],
  //           "0x"
  //         ),
  //       })
  //     ).to.be.reverted;

  //     const balanceAfter = await L2BaseToken.balanceOf(msgSender);
  //     expect(balanceBefore).to.equal(balanceAfter);

  //     const contractBalanceAfter = await L2BaseToken.balanceOf(mockContract.address);
  //     expect(contractBalanceBefore).to.equal(contractBalanceAfter);
  //   });

  //   it("revert more than balance", async () => {
  //     const balanceBefore = await L2BaseToken.balanceOf(msgSender);
  //     const contractBalanceBefore = await L2BaseToken.balanceOf(mockContract.address);
  //     const value = balanceBefore.add(1);

  //     await expect(
  //       extraAbiCaller.fallback({
  //         data: encodeExtraAbiCallerCalldata(
  //           messageValueSimulator.address,
  //           BigNumber.from(0),
  //           [value.toString(), mockContract.address, "0"],
  //           "0x"
  //         ),
  //       })
  //     ).to.be.reverted;

  //     const balanceAfter = await L2BaseToken.balanceOf(msgSender);
  //     expect(balanceBefore).to.equal(balanceAfter);

  //     const contractBalanceAfter = await L2BaseToken.balanceOf(mockContract.address);
  //     expect(contractBalanceBefore).to.equal(contractBalanceAfter);
  //   });
});

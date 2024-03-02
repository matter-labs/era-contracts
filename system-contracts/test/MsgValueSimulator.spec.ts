import type { TransferTest, TransferTestRecipient, TransferTestReentrantRecipient } from "../typechain";
import { REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS } from "./shared/constants";
import { getWallets, loadArtifact, setCode, getCode, deployContract } from "./shared/utils";
import { ethers } from "hardhat";
import type { Contract } from "ethers";
import { expect } from "chai";
import * as hre from "hardhat";
import { prepareEnvironment } from "./shared/mocks";

describe("MsgValueSimulator tests", function () {
  let oldMsgValueSimulatorCode: string;
  let testedMsgValueSimulatorCode: string;

  let transferTest: TransferTest;
  let recipient: TransferTestRecipient;
  let reentrantRecipient: TransferTestReentrantRecipient;

  before(async () => {
    await prepareEnvironment();

    oldMsgValueSimulatorCode = await getCode(REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS);
    transferTest = (await deployContract("TransferTest", [])) as TransferTest;
    recipient = (await deployContract("TransferTestRecipient", [])) as TransferTestRecipient;
    reentrantRecipient = (await deployContract("TransferTestReentrantRecipient", [])) as TransferTestReentrantRecipient;

    // Supplying ETH to the wallet
    await getWallets()[0].sendTransaction({
      to: transferTest.address,
      value: ethers.utils.parseEther("100.0"),
    });

    testedMsgValueSimulatorCode = (await loadArtifact("MsgValueSimulator")).bytecode;

    // Note that we have to overwrite the real address here, since it is the address
    // that receives the needed stipend from zk_evm.
    await setCode(REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS, testedMsgValueSimulatorCode);
  });

  it(".transfer/.send with empty value", async () => {
    await coldTransferTest(transferTest, recipient, "transfer", ethers.BigNumber.from(0));
    await coldTransferTest(transferTest, recipient, "send", ethers.BigNumber.from(0));
  });

  it(".transfer/.send with non-empty value", async () => {
    await coldTransferTest(transferTest, recipient, "transfer", ethers.utils.parseEther("1.0"));
    await coldTransferTest(transferTest, recipient, "send", ethers.utils.parseEther("1.0"));
  });

  it(".transfer/.send with empty value should not allow storage changes", async () => {
    await expect(coldTransferTest(transferTest, reentrantRecipient, "transfer", ethers.BigNumber.from(0), true)).to.be
      .rejected;
    await expect(coldTransferTest(transferTest, reentrantRecipient, "send", ethers.BigNumber.from(0), true)).to.be
      .rejected;
  });

  it(".transfer/.send with non-empty value should not allow storage changes", async () => {
    await expect(
      coldTransferTest(transferTest, recipient, "transfer", ethers.utils.parseEther("1.0"), true, {
        value: ethers.utils.parseEther("1.0"),
      })
    ).to.be.rejected;
    await expect(
      coldTransferTest(transferTest, recipient, "send", ethers.utils.parseEther("1.0"), true, {
        value: ethers.utils.parseEther("1.0"),
      })
    ).to.be.rejected;
  });

  after(async () => {
    await setCode(REAL_MSG_VALUE_SYSTEM_CONTRACT_ADDRESS, oldMsgValueSimulatorCode);
  });
});

async function coldTransferTest(
  transferTest: TransferTest,
  recipient: Contract,
  type: "transfer" | "send",
  value: ethers.BigNumber,
  warmUp: boolean = false,
  overrides: ethers.PayableOverrides = {}
) {
  // Need to mine a new batch to ensure that the behavior is independent between tests
  await hre.network.provider.send("hardhat_mine", ["0x100"]);

  if (type == "transfer") {
    await transferTest.transfer(recipient.address, value, warmUp, overrides);
  } else {
    await transferTest.send(recipient.address, value, warmUp, overrides);
  }
}

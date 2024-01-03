import { ethers, network } from "hardhat";
import { L1MessengerFactory } from "../typechain";
import type { L1Messenger } from "../typechain"; 
import { prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";
import type { Wallet } from "zksync-web3";
import {
  TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
  TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TEST_BOOTLOADER_FORMAL_ADDRESS
} from "./shared/constants";
import { expect } from "chai";
import { randomBytes } from "crypto";

describe("L1Messenger tests", () => {
  let l1Messenger: L1Messenger;
  let wallet: Wallet;
  let l1MessengerAccount: ethers.Signer;
  let knownCodeStorageAccount: ethers.Signer;
  let bootloaderAccount: ethers.Signer;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, "L1Messenger");
    l1Messenger = L1MessengerFactory.connect(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, wallet);
    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
    knownCodeStorageAccount = await ethers.getImpersonatedSigner(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS],
    });
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS],
    });
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
    });
  });

  describe("sendL2ToL1Message", async () => {
    it("should revert when not called by the system contract", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(randomBytes(32));
      const value = ethers.utils.hexlify(randomBytes(32));
      await expect(l1Messenger.connect(getWallets()[2]).sendL2ToL1Log(isService, key, value)).to.be.rejectedWith(
        "This method require the caller to be system contract"
      );
    });

    // TODO: previous ERROR (node) execution reverted: Error function_selector = 0x, data = 0x
    // tmp fixed by changing L1Messenger.sol line 75 & 124 from
    // txNumberInBlock: SYSTEM_CONTEXT_CONTRACT.txNumberInBlock() to fixed value

    it("should emit L2ToL1LogSent event when called by the system contract", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(randomBytes(32));
      const value = ethers.utils.hexlify(randomBytes(32));
      
      const txNumberInBlock = 1;
      const callResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock])
      };
      await setResult("SystemContext", "txNumberInBlock", [], callResult);

      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value))
        .to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([0, isService, txNumberInBlock, l1MessengerAccount.address, key, value]);
    });

    it("should emit L2ToL1LogSent event when called by the system contract with isService false", async () => {
      const isService = false;
      const key = ethers.utils.hexlify(randomBytes(32));
      const value = ethers.utils.hexlify(randomBytes(32));

      const txNumberInBlock = 1;
      const callResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock])
      };

      await setResult("SystemContext", "txNumberInBlock", [], callResult);
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value))
        .to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([0, isService, txNumberInBlock, l1MessengerAccount.address, key, value]);
    });

    it("should revert when called by the system contract with empty key & value", async () => {
      const isService = true;
      const key = ethers.utils.hexlify([]);
      const value = ethers.utils.hexlify([]);
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value)).to.be.rejected;
    });

    it("should revert when called by the system contract with key & value > 32 bytes", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(randomBytes(33));
      const value = ethers.utils.hexlify(randomBytes(33));
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value)).to.be.rejected;
    });
  });

  describe("sendToL1", async () => {
    it("should emit L1MessageSent & L2ToL1LogSent events", async () => {
      const message = ethers.utils.hexlify(randomBytes(32));
      const expectedHash = ethers.utils.keccak256(message);
      const expectedKey = ethers.utils
        .hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32)
        .toLowerCase();
  
      const txNumberInBlock = 1; 
      const callResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock])
      };
      await setResult("SystemContext", "txNumberInBlock", [], callResult);
  
      await expect(l1Messenger.connect(l1MessengerAccount).sendToL1(message))
        .to.emit(l1Messenger, "L1MessageSent")
        .withArgs(l1MessengerAccount.address, expectedHash, message)
        .and.to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([0, true, txNumberInBlock, l1Messenger.address, expectedKey, expectedHash]);
    });
  
    it("should emit L1MessageSent & L2ToL1LogSent events when called with default account", async () => {
      const message = ethers.utils.hexlify(randomBytes(64));
      const expectedHash = ethers.utils.keccak256(message);
      const expectedKey = ethers.utils.hexZeroPad(ethers.utils.hexStripZeros(wallet.address), 32).toLowerCase();
  
      const txNumberInBlock = 1;
      const callResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock])
      };
      await setResult("SystemContext", "txNumberInBlock", [], callResult);
  
      await expect(l1Messenger.sendToL1(message))
        .to.emit(l1Messenger, "L1MessageSent")
        .withArgs(wallet.address, expectedHash, message)
        .and.to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([0, true, txNumberInBlock, l1Messenger.address, expectedKey, expectedHash]);
    });
  });

  describe("requestBytecodeL1Publication", async () => {
    it("should revert when not called by known code storage contract", async () => {
      const byteCodeHash = ethers.utils.hexlify(randomBytes(32));
      await expect(l1Messenger.requestBytecodeL1Publication(byteCodeHash)).to.be.rejectedWith("Inappropriate caller");
    });

    it("shoud revert when byteCodeHash < 32 bytes, called by known code system contract", async () => {
      const byteCodeHash = ethers.utils.hexlify(randomBytes(8));
      await expect(l1Messenger.connect(knownCodeStorageAccount).requestBytecodeL1Publication(byteCodeHash)).to.be
        .rejected;
    });

    it("shoud revert when byteCodeHash > 32 bytes, called by known code system contract", async () => {
      const byteCodeHash = ethers.utils.hexlify(randomBytes(64));
      await expect(l1Messenger.connect(knownCodeStorageAccount).requestBytecodeL1Publication(byteCodeHash)).to.be
        .rejected;
    });

    it("should revert due to overflow created by unchecked block in function", async () => {
      const byteCodeHash = ethers.utils.hexlify(randomBytes(32));
      await expect(l1Messenger.connect(knownCodeStorageAccount).requestBytecodeL1Publication(byteCodeHash)).to.be
        .rejected;
    });

    it("shoud emit event, called by known code system contract", async () => {
      const byteCodeHash = ethers.utils.hexZeroPad("0x01", 32);
      await expect(l1Messenger.connect(knownCodeStorageAccount).requestBytecodeL1Publication(byteCodeHash))
        .to.emit(l1Messenger, "BytecodeL1PublicationRequested")
        .withArgs(byteCodeHash);
    });
  });

//   describe("publishPubdataAndClearState", async () => {
//       it("should revert when not called by bootloader", async () => {
//           const totalL2ToL1PubdataAndStateDiffs = ethers.utils.hexZeroPad("0x01", 32);
//           await expect(l1Messenger.connect(getWallets()[2]).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)).to.be.rejectedWith("Callable only by the bootloader");
//       });

//       it("should revert Too many L2->L1 logs", async () => {
//         const totalL2ToL1PubdataAndStateDiffs = ethers.utils.hexZeroPad(ethers.constants.MaxUint256.toHexString(), 32);
//         await expect(l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)).to.be.rejectedWith("Too many L2->L1 logs");
//       })
//   });
});

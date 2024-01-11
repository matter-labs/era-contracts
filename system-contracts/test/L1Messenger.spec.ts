import { ethers, network } from "hardhat";
import { L1MessengerFactory } from "../typechain";
import type { L1Messenger } from "../typechain";
import { prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getCode, getWallets } from "./shared/utils";
import { utils } from "zksync-web3";
import type { Wallet } from "zksync-web3";
import {
  TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TWO_IN_256,
} from "./shared/constants";
import { expect } from "chai";
import { BigNumber } from "ethers";
import type { BytesLike } from "ethers";
import { randomBytes } from "crypto";

describe("L1Messenger tests", () => {
  let l1Messenger: L1Messenger;
  let wallet: Wallet;
  let l1MessengerAccount: ethers.Signer;
  let knownCodeStorageAccount: ethers.Signer;
  let bootloaderAccount: ethers.Signer;
  let numberOfLogs: number = 0;
  let numberOfMessages: number = 0;
  let numberOfBytecodes: number = 0;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, "L1Messenger");
    l1Messenger = L1MessengerFactory.connect(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, wallet);
    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
    knownCodeStorageAccount = await ethers.getImpersonatedSigner(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS],
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

  describe("sendL2ToL1Log", async () => {
    it("should revert when not called by the system contract", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(randomBytes(32));
      const value = ethers.utils.hexlify(randomBytes(32));
      await expect(l1Messenger.connect(getWallets()[2]).sendL2ToL1Log(isService, key, value)).to.be.rejectedWith(
        "This method require the caller to be system contract"
      );
    });

    it("should emit L2ToL1LogSent event when called by the system contract", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(randomBytes(32));
      const value = ethers.utils.hexlify(randomBytes(32));

      const txNumberInBlock = 1;
      const callResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock]),
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
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock]),
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

    it("should revert when called by the system contract with key & value < 32 bytes", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(randomBytes(31));
      const value = ethers.utils.hexlify(randomBytes(31));
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
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock]),
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
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock]),
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

    it("shoud emit event, called by known code system contract", async () => {
      const bytecode = await getCode(l1Messenger.address);
      const bytecodeHash = await ethers.utils.hexlify(utils.hashBytecode(bytecode));
      await expect(
        l1Messenger.connect(knownCodeStorageAccount).requestBytecodeL1Publication(bytecodeHash, { gasLimit: 130000000 })
      )
        .to.emit(l1Messenger, "BytecodeL1PublicationRequested")
        .withArgs(bytecodeHash);
    });
  });

  // TODO: IN PROGRESS
  describe("publishPubdataAndClearState", async () => {
    it("publishPubdataAndClearState passes correctly", async () => {
      // ====================================================================================================
      // sendL2ToL1Log()
      const isService = true;
      const key = Buffer.alloc(32, 1);
      const value = Buffer.alloc(32, 2);

      const txNumberInBlock = 1;
      const callResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock]),
      };
      await setResult("SystemContext", "txNumberInBlock", [], callResult);
      await (await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value)).wait();

      const firstLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
        key,
        value,
      ]);
      numberOfLogs++;

      // ====================================================================================================
      // sendToL1()
      const message = Buffer.alloc(32, 3);
      const txNumberInBlock2 = 1;
      const callResult2 = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock2]),
      };
      await setResult("SystemContext", "txNumberInBlock", [], callResult2);
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(message)).wait();

      const senderAddress = ethers.utils
        .hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32)
        .toLowerCase();
      const messageHash = ethers.utils.keccak256(message);

      const secondLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1Messenger.address, 20),
        senderAddress,
        messageHash,
      ]);
      const currentMessageLength = 32;
      numberOfMessages++;
      numberOfLogs++;

      // ====================================================================================================
      // requestBytecodeL1Publication()
      const bytecode = await getCode(l1Messenger.address);
      const bytecodeHash = await ethers.utils.hexlify(utils.hashBytecode(bytecode));
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(bytecodeHash, { gasLimit: 130000000 })
      ).wait();
      numberOfBytecodes++;
      const lengthOfBytecode = bytecode.length;

      // ====================================================================================================
      // Prepare data for publishPubdataAndClearState()
      const numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
      const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
      const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
      const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
      const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

      // ====================================================================================================
      // Prepare state diffs - taken from Compressor.spec.ts
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901230",
          index: 0,
          initValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901231"),
          finalValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901230"),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901232",
          index: 1,
          initValue: TWO_IN_256.sub(1),
          finalValue: BigNumber.from(1),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 0,
          initValue: TWO_IN_256.div(2),
          finalValue: BigNumber.from(1),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901236",
          index: 2323,
          initValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901237"),
          finalValue: BigNumber.from("0x0239329298382323782378478237842378478237847237237872373272373272"),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901238",
          index: 2,
          initValue: BigNumber.from(0),
          finalValue: BigNumber.from(1),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      const compressedStateDiffs = compressStateDiffs(4, stateDiffs);
      const numberOfStateDiffs = stateDiffs.length;
      const enumerationIndexSize = 4;

      // ====================================================================================================
      // mocking compressor
      const stateDiffHash = ethers.utils.keccak256(encodedStateDiffs);
      const verifyCompressedStateDiffsResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [stateDiffHash]),
      };

      await setResult(
        "Compressor",
        "verifyCompressedStateDiffs",
        [numberOfStateDiffs, enumerationIndexSize, encodedStateDiffs, compressedStateDiffs],
        verifyCompressedStateDiffsResult
      );

      // ====================================================================================================
      // Prepare state diffs data for publishPubdataAndClearState()
      const version = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 1);
      const compressedStateDiffsBuffer = ethers.utils.arrayify(compressedStateDiffs);
      const compressedStateDiffsLength = compressedStateDiffsBuffer.length;
      const compressedStateDiffsSizeBytes = ethers.utils.hexZeroPad(
        ethers.utils.hexlify(compressedStateDiffsLength),
        3
      );
      const enumerationIndexSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(enumerationIndexSize), 1);
      const numberOfStateDiffsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfStateDiffs), 4);

      // ====================================================================================================
      // Prepare totalL2ToL1PubdataAndStateDiffs
      const totalL2ToL1PubdataAndStateDiffs = ethers.utils.concat([
        numberOfLogsBytes,
        firstLog,
        secondLog,
        numberOfMessagesBytes,
        currentMessageLengthBytes,
        message,
        numberOfBytecodesBytes,
        lengthOfBytecodeBytes,
        bytecode,
        version,
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs,
      ]);

      // ====================================================================================================
      // publishPubdataAndClearState()
      await (
        await l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs, { gasLimit: 10000000 })
      ).wait();

      numberOfLogs = 0;
      numberOfMessages = 0;
      numberOfBytecodes = 0;
    });

    it("should revert Too many L2->L1 logs", async () => {
      // ====================================================================================================
      // sendL2ToL1Log()
      const isService = true;
      const key = Buffer.alloc(32, 1);
      const value = Buffer.alloc(32, 2);

      const txNumberInBlock = 1;
      const callResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock]),
      };
      await setResult("SystemContext", "txNumberInBlock", [], callResult);
      await (await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value)).wait();

      const firstLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
        key,
        value,
      ]);
      numberOfLogs++;

      // ====================================================================================================
      // sendToL1()
      const message = Buffer.alloc(32, 3);
      const txNumberInBlock2 = 1;
      const callResult2 = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock2]),
      };
      await setResult("SystemContext", "txNumberInBlock", [], callResult2);
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(message)).wait();

      const senderAddress = ethers.utils
        .hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32)
        .toLowerCase();
      const messageHash = ethers.utils.keccak256(message);
      const secondLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1Messenger.address, 20),
        senderAddress,
        messageHash,
      ]);
      const currentMessageLength = 32;
      numberOfMessages++;
      numberOfLogs++;

      // ====================================================================================================
      // requestBytecodeL1Publication()
      const bytecode = await getCode(l1Messenger.address);
      const bytecodeHash = await ethers.utils.hexlify(utils.hashBytecode(bytecode));
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(bytecodeHash, { gasLimit: 130000000 })
      ).wait();
      numberOfBytecodes++;
      const lengthOfBytecode = bytecode.length;

      // ====================================================================================================
      // Prepare data for publishPubdataAndClearState()
      let numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
      const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
      const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
      const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
      const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

      // ====================================================================================================
      // Prepare state diffs - taken from Compressor.spec.ts
      const stateDiffs = [
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901230",
          index: 0,
          initValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901231"),
          finalValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901230"),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901232",
          index: 1,
          initValue: TWO_IN_256.sub(1),
          finalValue: BigNumber.from(1),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901234",
          index: 0,
          initValue: TWO_IN_256.div(2),
          finalValue: BigNumber.from(1),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901236",
          index: 2323,
          initValue: BigNumber.from("0x1234567890123456789012345678901234567890123456789012345678901237"),
          finalValue: BigNumber.from("0x0239329298382323782378478237842378478237847237237872373272373272"),
        },
        {
          key: "0x1234567890123456789012345678901234567890123456789012345678901238",
          index: 2,
          initValue: BigNumber.from(0),
          finalValue: BigNumber.from(1),
        },
      ];
      const encodedStateDiffs = encodeStateDiffs(stateDiffs);
      const compressedStateDiffs = compressStateDiffs(4, stateDiffs);
      const numberOfStateDiffs = stateDiffs.length;
      const enumerationIndexSize = 4;

      // ====================================================================================================
      // mocking compressor
      const stateDiffHash = ethers.utils.keccak256(encodedStateDiffs);
      const verifyCompressedStateDiffsResult = {
        failure: false,
        returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [stateDiffHash]),
      };

      await setResult(
        "Compressor",
        "verifyCompressedStateDiffs",
        [numberOfStateDiffs, enumerationIndexSize, encodedStateDiffs, compressedStateDiffs],
        verifyCompressedStateDiffsResult
      );

      // ====================================================================================================
      // Prepare state diffs data for publishPubdataAndClearState()
      const version = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 1);
      const compressedStateDiffsBuffer = ethers.utils.arrayify(compressedStateDiffs);
      const compressedStateDiffsLength = compressedStateDiffsBuffer.length;
      const compressedStateDiffsSizeBytes = ethers.utils.hexZeroPad(
        ethers.utils.hexlify(compressedStateDiffsLength),
        3
      );
      const enumerationIndexSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(enumerationIndexSize), 1);
      const numberOfStateDiffsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfStateDiffs), 4);

      // ====================================================================================================
      // Prepare totalL2ToL1PubdataAndStateDiffs
      // set numberOfLogsBytes to 0x900 to trigger the revert (max value is 0x800)
      numberOfLogsBytes = 0x900;
      const totalL2ToL1PubdataAndStateDiffs = ethers.utils.concat([
        numberOfLogsBytes,
        firstLog,
        secondLog,
        numberOfMessagesBytes,
        currentMessageLengthBytes,
        message,
        numberOfBytecodesBytes,
        lengthOfBytecodeBytes,
        bytecode,
        version,
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs,
      ]);

      // ====================================================================================================
      // publishPubdataAndClearState()

      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("Too many L2->L1 logs");

      numberOfLogs = 0;
      numberOfMessages = 0;
      numberOfBytecodes = 0;
    });
  });
});

// taken from Compressor.spec.ts, possibly move to utils
interface StateDiff {
  key: BytesLike;
  index: number;
  initValue: BigNumber;
  finalValue: BigNumber;
}

function encodeStateDiffs(stateDiffs: StateDiff[]): string {
  const rawStateDiffs = [];
  for (const stateDiff of stateDiffs) {
    rawStateDiffs.push(
      ethers.utils.solidityPack(
        ["address", "bytes32", "bytes32", "uint64", "uint256", "uint256", "bytes"],
        [
          ethers.constants.AddressZero,
          ethers.constants.HashZero,
          stateDiff.key,
          stateDiff.index,
          stateDiff.initValue,
          stateDiff.finalValue,
          "0x" + "00".repeat(116),
        ]
      )
    );
  }
  return ethers.utils.hexlify(ethers.utils.concat(rawStateDiffs));
}

function compressStateDiffs(enumerationIndexSize: number, stateDiffs: StateDiff[]): string {
  let num_initial = 0;
  const initial = [];
  const repeated = [];
  for (const stateDiff of stateDiffs) {
    const addition = stateDiff.finalValue.sub(stateDiff.initValue).add(TWO_IN_256).mod(TWO_IN_256);
    const subtraction = stateDiff.initValue.sub(stateDiff.finalValue).add(TWO_IN_256).mod(TWO_IN_256);
    let op = 3;
    let min = stateDiff.finalValue;
    if (addition.lt(min)) {
      min = addition;
      op = 1;
    }
    if (subtraction.lt(min)) {
      min = subtraction;
      op = 2;
    }
    if (min.gte(BigNumber.from(2).pow(248))) {
      min = stateDiff.finalValue;
      op = 0;
    }
    let len = 0;
    const minHex = min.eq(0) ? "0x" : min.toHexString();
    if (op > 0) {
      len = (minHex.length - 2) / 2;
    }
    const metadata = (len << 3) + op;
    const enumerationIndexType = "uint" + (enumerationIndexSize * 8).toString();
    if (stateDiff.index === 0) {
      num_initial += 1;
      initial.push(ethers.utils.solidityPack(["bytes32", "uint8", "bytes"], [stateDiff.key, metadata, minHex]));
    } else {
      repeated.push(
        ethers.utils.solidityPack([enumerationIndexType, "uint8", "bytes"], [stateDiff.index, metadata, minHex])
      );
    }
  }
  return ethers.utils.hexlify(
    ethers.utils.concat([ethers.utils.solidityPack(["uint16"], [num_initial]), ...initial, ...repeated])
  );
}

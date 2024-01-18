import { ethers, network } from "hardhat";
import type { L1Messenger } from "../typechain";
import { L1MessengerFactory } from "../typechain";
import { prepareEnvironment, setResult } from "./shared/mocks";
import type { StateDiff } from "./shared/utils";
import { compressStateDiffs, deployContractOnAddress, encodeStateDiffs, getCode, getWallets } from "./shared/utils";
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
  let stateDiffs: StateDiff[];
  let encodedStateDiffs: string;
  let compressedStateDiffs: string;
  let numberOfStateDiffs: number;
  let enumerationIndexSize: number;
  let isService: boolean;
  let key: Buffer;
  let value: Buffer;
  let message: Buffer;
  let messageHash: string;
  let txNumberInBlock: number;
  let callResult: unknown;
  let firstLog: string;
  let secondLog: string;
  let currentMessageLength: number;
  let senderAddress: string;
  let bytecode: string;
  let lengthOfBytecode: number;
  let lengthOfBytecodeBytes: string;
  let bytecodeHash: string;
  let currentMessageLengthBytes: string;
  let version: string;
  let enumerationIndexSizeBytes: string;
  let stateDiffHash: string;
  let verifyCompressedStateDiffsResult: unknown;
  let numberOfStateDiffsBytes: string;
  let compressedStateDiffsBuffer: Uint8Array;
  let compressedStateDiffsLength: number;
  let compressedStateDiffsSizeBytes: string;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, "L1Messenger");
    l1Messenger = L1MessengerFactory.connect(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, wallet);
    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
    knownCodeStorageAccount = await ethers.getImpersonatedSigner(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    // setup - code that occured in many test cases
    stateDiffs = [
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
    encodedStateDiffs = encodeStateDiffs(stateDiffs);
    compressedStateDiffs = compressStateDiffs(4, stateDiffs);
    numberOfStateDiffs = stateDiffs.length;
    enumerationIndexSize = 4;
    isService = true;
    key = Buffer.alloc(32, 1);
    value = Buffer.alloc(32, 2);
    message = Buffer.alloc(32, 3);
    messageHash = ethers.utils.keccak256(message);
    senderAddress = ethers.utils.hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32).toLowerCase();
    currentMessageLength = 32;
    txNumberInBlock = 1;
    callResult = {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [txNumberInBlock]),
    };
    firstLog = ethers.utils.concat([
      ethers.utils.hexlify([0]),
      ethers.utils.hexlify(1),
      ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
      ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
      key,
      value,
    ]);
    secondLog = ethers.utils.concat([
      ethers.utils.hexlify([0]),
      ethers.utils.hexlify(1),
      ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
      ethers.utils.hexZeroPad(l1Messenger.address, 20),
      senderAddress,
      messageHash,
    ]);
    bytecode = await getCode(l1Messenger.address);
    lengthOfBytecode = ethers.utils.arrayify(bytecode).length;
    lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);
    bytecodeHash = await ethers.utils.hexlify(utils.hashBytecode(bytecode));
    await setResult("SystemContext", "txNumberInBlock", [], callResult);
    currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
    version = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 1);
    enumerationIndexSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(enumerationIndexSize), 1);
    stateDiffHash = ethers.utils.keccak256(encodedStateDiffs);
    verifyCompressedStateDiffsResult = {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [stateDiffHash]),
    };
    await setResult(
      "Compressor",
      "verifyCompressedStateDiffs",
      [numberOfStateDiffs, enumerationIndexSize, encodedStateDiffs, compressedStateDiffs],
      verifyCompressedStateDiffsResult
    );
    numberOfStateDiffsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfStateDiffs), 4);
    compressedStateDiffsBuffer = ethers.utils.arrayify(compressedStateDiffs);
    compressedStateDiffsLength = compressedStateDiffsBuffer.length;
    compressedStateDiffsSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(compressedStateDiffsLength), 3);
  });

  // this part is necessary to clean the state of L1Messenger contract
  after(async () => {
    // third log from test case: "sendL2ToL1Log" ->
    // "should emit L2ToL1LogSent event when called by the system contract"
    // same as firstLog
    numberOfLogs++;
    // fourth log from test case: "sendL2ToL1Log" ->
    // "-||- with isService false"
    const fourthLog = ethers.utils.concat([
      ethers.utils.hexlify([0]),
      ethers.utils.hexlify([0]),
      ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
      ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
      key,
      value,
    ]);
    numberOfLogs++;
    // fifth log from test case: "sendToL1" ->
    // "should emit L1MessageSent & L2ToL1LogSent events"
    // same as secondLog
    numberOfLogs++;
    numberOfMessages++;
    // 1 more bytecde from test case: "requestBytecodeL1Publication"
    numberOfBytecodes++;

    const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
      numberOfLogs,
      [firstLog, secondLog, firstLog, fourthLog, secondLog],
      numberOfMessages,
      [
        { lengthBytes: currentMessageLengthBytes, content: message },
        { lengthBytes: currentMessageLengthBytes, content: message },
      ],
      numberOfBytecodes,
      [
        { lengthBytes: lengthOfBytecodeBytes, content: bytecode },
        { lengthBytes: lengthOfBytecodeBytes, content: bytecode },
      ],
      version,
      compressedStateDiffsSizeBytes,
      enumerationIndexSizeBytes,
      compressedStateDiffs,
      numberOfStateDiffsBytes,
      encodedStateDiffs
    );

    await l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs);
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

  describe("publishPubdataAndClearState", async () => {
    it("publishPubdataAndClearState passes correctly", async () => {
      await (await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value)).wait();
      numberOfLogs++;
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(message)).wait();
      numberOfMessages++;
      numberOfLogs++;
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(bytecodeHash, { gasLimit: 130000000 })
      ).wait();
      numberOfBytecodes++;

      // Prepare totalL2ToL1PubdataAndStateDiffs
      const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        numberOfLogs,
        [firstLog, secondLog],
        numberOfMessages,
        [{ lengthBytes: currentMessageLengthBytes, content: message }],
        numberOfBytecodes,
        [{ lengthBytes: lengthOfBytecodeBytes, content: bytecode }],
        version,
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs
      );
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
      // Prepare totalL2ToL1PubdataAndStateDiffs
      // set numberOfLogsBytes to 0x900 to trigger the revert (max value is 0x800)
      const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        0x900,
        [firstLog, secondLog],
        numberOfMessages,
        [{ lengthBytes: currentMessageLengthBytes, content: message }],
        numberOfBytecodes,
        [{ lengthBytes: lengthOfBytecodeBytes, content: bytecode }],
        version,
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs
      );
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("Too many L2->L1 logs");
    });

    it("should revert logshashes mismatch", async () => {
      await (await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, key, value)).wait();
      numberOfLogs++;
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(message)).wait();
      numberOfMessages++;
      numberOfLogs++;

      // Prepare totalL2ToL1PubdataAndStateDiffs
      // set secondlog hash to random data to trigger the revert
      const secondLogModified = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify(1),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1Messenger.address, 20),
        senderAddress,
        ethers.utils.hexlify(randomBytes(32)),
      ]);
      const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        numberOfLogs,
        [firstLog, secondLogModified],
        numberOfMessages,
        [{ lengthBytes: currentMessageLengthBytes, content: message }],
        numberOfBytecodes,
        [{ lengthBytes: lengthOfBytecodeBytes, content: bytecode }],
        version,
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs
      );
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("reconstructedChainedLogsHash is not equal to chainedLogsHash");
    });

    it("should revert chainedMessageHash mismatch", async () => {
      // Prepare totalL2ToL1PubdataAndStateDiffs
      // Buffer.alloc(32, 6), to trigger the revert
      const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        numberOfLogs,
        [firstLog, secondLog],
        numberOfMessages,
        [{ lengthBytes: currentMessageLengthBytes, content: Buffer.alloc(32, 6) }],
        numberOfBytecodes,
        [{ lengthBytes: lengthOfBytecodeBytes, content: bytecode }],
        version,
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs
      );
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("reconstructedChainedMessagesHash is not equal to chainedMessagesHash");
    });

    it("should revert state diff compression version mismatch", async () => {
      // Prepare totalL2ToL1PubdataAndStateDiffs
      // modify version to trigger the revert
      const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        numberOfLogs,
        [firstLog, secondLog],
        numberOfMessages,
        [{ lengthBytes: currentMessageLengthBytes, content: message }],
        numberOfBytecodes,
        [{ lengthBytes: lengthOfBytecodeBytes, content: bytecode }],
        ethers.utils.hexZeroPad(ethers.utils.hexlify(111), 1),
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs
      );
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("state diff compression version mismatch");
    });

    it("should revert extra data", async () => {
      // Prepare totalL2ToL1PubdataAndStateDiffs
      // add extra data to trigger the revert
      let totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        numberOfLogs,
        [firstLog, secondLog],
        numberOfMessages,
        [{ lengthBytes: currentMessageLengthBytes, content: message }],
        numberOfBytecodes,
        [{ lengthBytes: lengthOfBytecodeBytes, content: bytecode }],
        version,
        compressedStateDiffsSizeBytes,
        enumerationIndexSizeBytes,
        compressedStateDiffs,
        numberOfStateDiffsBytes,
        encodedStateDiffs
      );
      totalL2ToL1PubdataAndStateDiffs = ethers.utils.concat([totalL2ToL1PubdataAndStateDiffs, Buffer.alloc(1, 64)]);
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("Extra data in the totalL2ToL1Pubdata array");
    });
  });

  describe("sendL2ToL1Log", async () => {
    it("should revert when not called by the system contract", async () => {
      await expect(l1Messenger.sendL2ToL1Log(isService, key, value)).to.be.rejectedWith(
        "This method require the caller to be system contract"
      );
    });

    it("should emit L2ToL1LogSent event when called by the system contract", async () => {
      await expect(
        l1Messenger
          .connect(l1MessengerAccount)
          .sendL2ToL1Log(isService, ethers.utils.hexlify(key), ethers.utils.hexlify(value))
      )
        .to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([
          0,
          isService,
          txNumberInBlock,
          l1MessengerAccount.address,
          ethers.utils.hexlify(key),
          ethers.utils.hexlify(value),
        ]);
    });

    it("should emit L2ToL1LogSent event when called by the system contract with isService false", async () => {
      await expect(
        l1Messenger
          .connect(l1MessengerAccount)
          .sendL2ToL1Log(false, ethers.utils.hexlify(key), ethers.utils.hexlify(value))
      )
        .to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([
          0,
          false,
          txNumberInBlock,
          l1MessengerAccount.address,
          ethers.utils.hexlify(key),
          ethers.utils.hexlify(value),
        ]);
    });

    it("should revert when called by the system contract with empty key & value", async () => {
      const emptyKV = ethers.utils.hexlify([]);
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, emptyKV, emptyKV)).to.be.rejected;
    });

    it("should revert when called by the system contract with key & value > 32 bytes", async () => {
      const oversizedKV = ethers.utils.hexlify(randomBytes(33));
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, oversizedKV, oversizedKV)).to.be
        .rejected;
    });

    it("should revert when called by the system contract with key & value < 32 bytes", async () => {
      const undersizedKV = ethers.utils.hexlify(randomBytes(31));
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(isService, undersizedKV, undersizedKV)).to.be
        .rejected;
    });
  });

  describe("sendToL1", async () => {
    it("should emit L1MessageSent & L2ToL1LogSent events", async () => {
      const expectedKey = ethers.utils
        .hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32)
        .toLowerCase();
      await expect(l1Messenger.connect(l1MessengerAccount).sendToL1(message))
        .to.emit(l1Messenger, "L1MessageSent")
        .withArgs(l1MessengerAccount.address, messageHash, message)
        .and.to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([0, true, txNumberInBlock, l1Messenger.address, expectedKey, messageHash]);
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
      await expect(
        l1Messenger.connect(knownCodeStorageAccount).requestBytecodeL1Publication(bytecodeHash, { gasLimit: 130000000 })
      )
        .to.emit(l1Messenger, "BytecodeL1PublicationRequested")
        .withArgs(bytecodeHash);
    });
  });
});

// helpers
interface DataPair {
  lengthBytes: string;
  content: string;
}

function createTotalL2ToL1PubdataAndStateDiffs(
  numberOfLogs: number,
  logs: string[],
  numberOfMessages: number,
  messages: DataPair[],
  numberOfBytecodes: number,
  bytecodes: DataPair[],
  version: string,
  compressedStateDiffsSizeBytes: string,
  enumerationIndexSizeBytes: string,
  compressedStateDiffs: string,
  numberOfStateDiffsBytes: string,
  encodedStateDiffs: string
): string {
  const messagePairs = [];
  for (let i = 0; i < numberOfMessages; i++) {
    messagePairs.push(messages[i].lengthBytes, messages[i].content);
  }

  const bytecodePairs = [];
  for (let i = 0; i < numberOfBytecodes; i++) {
    bytecodePairs.push(bytecodes[i].lengthBytes, bytecodes[i].content);
  }

  return ethers.utils.concat([
    ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4),
    ...logs,
    ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4),
    ...messagePairs,
    ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4),
    ...bytecodePairs,
    version,
    compressedStateDiffsSizeBytes,
    enumerationIndexSizeBytes,
    compressedStateDiffs,
    numberOfStateDiffsBytes,
    encodedStateDiffs,
  ]);
}

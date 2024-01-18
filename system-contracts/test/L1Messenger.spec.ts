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
  let stateDiffsSetupData: StateDiffSetupData;
  let logData: LogData;
  let logs: string[];
  let bytecodeData: BytecodeData;

  // let bytecode: string;
  // let lengthOfBytecodeBytes: string;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, "L1Messenger");
    l1Messenger = L1MessengerFactory.connect(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, wallet);
    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
    knownCodeStorageAccount = await ethers.getImpersonatedSigner(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    // setup
    stateDiffsSetupData = await setupStateDiffs();
    logData = setupLogData();
    logs = createLogs(l1MessengerAccount, l1Messenger, logData);
    bytecodeData = await setupBytecodeData(l1Messenger.address);
    
    await setResult("SystemContext", "txNumberInBlock", [], {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [1]),
    });
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
      ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 2),
      ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
      logData.key,
      logData.value,
    ]);
    numberOfLogs++;
    // fifth log from test case: "sendToL1" ->
    // "should emit L1MessageSent & L2ToL1LogSent events"
    // same as secondLog
    numberOfLogs++;
    numberOfMessages++;
    // 1 more bytecode from test case: "requestBytecodeL1Publication"
    numberOfBytecodes++;

    const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
      numberOfLogs,
      [...logs, logs[0], fourthLog, logs[1]],
      numberOfMessages,
      [
        { lengthBytes: logData.currentMessageLengthBytes, content: logData.message },
        { lengthBytes: logData.currentMessageLengthBytes, content: logData.message },
      ],
      numberOfBytecodes,
      [
        bytecodeData,
        bytecodeData,
      ],
      stateDiffsSetupData.compressedStateDiffsSizeBytes,
      stateDiffsSetupData.enumerationIndexSizeBytes,
      stateDiffsSetupData.compressedStateDiffs,
      stateDiffsSetupData.numberOfStateDiffsBytes,
      stateDiffsSetupData.encodedStateDiffs
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
      await (await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(logData.isService, logData.key, logData.value)).wait();
      numberOfLogs++;
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(logData.message)).wait();
      numberOfMessages++;
      numberOfLogs++;
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(await ethers.utils.hexlify(utils.hashBytecode(bytecodeData.content)), { gasLimit: 130000000 })
      ).wait();
      numberOfBytecodes++;

      // Prepare totalL2ToL1PubdataAndStateDiffs
      const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        numberOfLogs,
        logs,
        numberOfMessages,
        [{ lengthBytes: logData.currentMessageLengthBytes, content: logData.message }],
        numberOfBytecodes,
        [bytecodeData],
        stateDiffsSetupData.compressedStateDiffsSizeBytes,
        stateDiffsSetupData.enumerationIndexSizeBytes,
        stateDiffsSetupData.compressedStateDiffs,
        stateDiffsSetupData.numberOfStateDiffsBytes,
        stateDiffsSetupData.encodedStateDiffs
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
        logs,
        numberOfMessages,
        [{ lengthBytes: logData.currentMessageLengthBytes, content: logData.message }],
        numberOfBytecodes,
        [bytecodeData],
        stateDiffsSetupData.compressedStateDiffsSizeBytes,
        stateDiffsSetupData.enumerationIndexSizeBytes,
        stateDiffsSetupData.compressedStateDiffs,
        stateDiffsSetupData.numberOfStateDiffsBytes,
        stateDiffsSetupData.encodedStateDiffs
      );
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("Too many L2->L1 logs");
    });

    it("should revert logshashes mismatch", async () => {
      await (await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(logData.isService, logData.key, logData.value)).wait();
      numberOfLogs++;
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(logData.message)).wait();
      numberOfMessages++;
      numberOfLogs++;

      // Prepare totalL2ToL1PubdataAndStateDiffs
      // set secondlog hash to random data to trigger the revert
      const secondLogModified = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify(1),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 2),
        ethers.utils.hexZeroPad(l1Messenger.address, 20),
        ethers.utils.hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32).toLowerCase(),
        ethers.utils.hexlify(randomBytes(32)),
      ]);
      const totalL2ToL1PubdataAndStateDiffs = createTotalL2ToL1PubdataAndStateDiffs(
        numberOfLogs,
        [logs[0], secondLogModified],
        numberOfMessages,
        [{ lengthBytes: logData.currentMessageLengthBytes, content: logData.message }],
        numberOfBytecodes,
        [bytecodeData],
        stateDiffsSetupData.compressedStateDiffsSizeBytes,
        stateDiffsSetupData.enumerationIndexSizeBytes,
        stateDiffsSetupData.compressedStateDiffs,
        stateDiffsSetupData.numberOfStateDiffsBytes,
        stateDiffsSetupData.encodedStateDiffs
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
        logs,
        numberOfMessages,
        [{ lengthBytes: logData.currentMessageLengthBytes, content: Buffer.alloc(32, 6) }],
        numberOfBytecodes,
        [bytecodeData],
        stateDiffsSetupData.compressedStateDiffsSizeBytes,
        stateDiffsSetupData.enumerationIndexSizeBytes,
        stateDiffsSetupData.compressedStateDiffs,
        stateDiffsSetupData.numberOfStateDiffsBytes,
        stateDiffsSetupData.encodedStateDiffs
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
        logs,
        numberOfMessages,
        [{ lengthBytes: logData.currentMessageLengthBytes, content: logData.message }],
        numberOfBytecodes,
        [bytecodeData],
        stateDiffsSetupData.compressedStateDiffsSizeBytes,
        stateDiffsSetupData.enumerationIndexSizeBytes,
        stateDiffsSetupData.compressedStateDiffs,
        stateDiffsSetupData.numberOfStateDiffsBytes,
        stateDiffsSetupData.encodedStateDiffs,
        ethers.utils.hexZeroPad(ethers.utils.hexlify(111), 1),
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
        logs,
        numberOfMessages,
        [{ lengthBytes: logData.currentMessageLengthBytes, content: logData.message }],
        numberOfBytecodes,
        [bytecodeData],
        stateDiffsSetupData.compressedStateDiffsSizeBytes,
        stateDiffsSetupData.enumerationIndexSizeBytes,
        stateDiffsSetupData.compressedStateDiffs,
        stateDiffsSetupData.numberOfStateDiffsBytes,
        stateDiffsSetupData.encodedStateDiffs
      );
      totalL2ToL1PubdataAndStateDiffs = ethers.utils.concat([totalL2ToL1PubdataAndStateDiffs, Buffer.alloc(1, 64)]);
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("Extra data in the totalL2ToL1Pubdata array");
    });
  });

  describe("sendL2ToL1Log", async () => {
    it("should revert when not called by the system contract", async () => {
      await expect(l1Messenger.sendL2ToL1Log(logData.isService, logData.key, logData.value)).to.be.rejectedWith(
        "This method require the caller to be system contract"
      );
    });

    it("should emit L2ToL1LogSent event when called by the system contract", async () => {
      await expect(
        l1Messenger
          .connect(l1MessengerAccount)
          .sendL2ToL1Log(logData.isService, ethers.utils.hexlify(logData.key), ethers.utils.hexlify(logData.value))
      )
        .to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([
          0,
          logData.isService,
          1,
          l1MessengerAccount.address,
          ethers.utils.hexlify(logData.key),
          ethers.utils.hexlify(logData.value),
        ]);
    });

    it("should emit L2ToL1LogSent event when called by the system contract with isService false", async () => {
      await expect(
        l1Messenger
          .connect(l1MessengerAccount)
          .sendL2ToL1Log(false, ethers.utils.hexlify(logData.key), ethers.utils.hexlify(logData.value))
      )
        .to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([
          0,
          false,
          1,
          l1MessengerAccount.address,
          ethers.utils.hexlify(logData.key),
          ethers.utils.hexlify(logData.value),
        ]);
    });

    it("should revert when called by the system contract with empty key & value", async () => {
      const emptyKV = ethers.utils.hexlify([]);
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(logData.isService, emptyKV, emptyKV)).to.be.rejected;
    });

    it("should revert when called by the system contract with key & value > 32 bytes", async () => {
      const oversizedKV = ethers.utils.hexlify(randomBytes(33));
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(logData.isService, oversizedKV, oversizedKV)).to.be
        .rejected;
    });

    it("should revert when called by the system contract with key & value < 32 bytes", async () => {
      const undersizedKV = ethers.utils.hexlify(randomBytes(31));
      await expect(l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(logData.isService, undersizedKV, undersizedKV)).to.be
        .rejected;
    });
  });

  describe("sendToL1", async () => {
    it("should emit L1MessageSent & L2ToL1LogSent events", async () => {
      const expectedKey = ethers.utils
        .hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32)
        .toLowerCase();
      await expect(l1Messenger.connect(l1MessengerAccount).sendToL1(logData.message))
        .to.emit(l1Messenger, "L1MessageSent")
        .withArgs(l1MessengerAccount.address, ethers.utils.keccak256(logData.message), logData.message)
        .and.to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([0, true, 1, l1Messenger.address, expectedKey, ethers.utils.keccak256(logData.message)]);
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
        l1Messenger.connect(knownCodeStorageAccount).requestBytecodeL1Publication(await ethers.utils.hexlify(utils.hashBytecode(bytecodeData.content)), { gasLimit: 130000000 })
      )
        .to.emit(l1Messenger, "BytecodeL1PublicationRequested")
        .withArgs(await ethers.utils.hexlify(utils.hashBytecode(bytecodeData.content)));
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
  compressedStateDiffsSizeBytes: string,
  enumerationIndexSizeBytes: string,
  compressedStateDiffs: string,
  numberOfStateDiffsBytes: string,
  encodedStateDiffs: string,
  version: string = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 1),
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

// STATE DIFFS 
interface StateDiffSetupData {
  encodedStateDiffs: string;
  compressedStateDiffs: string;
  enumerationIndexSizeBytes: string;
  numberOfStateDiffsBytes: string;
  compressedStateDiffsSizeBytes: string;
}

async function setupStateDiffs(): Promise<StateDiffSetupData> {
  const stateDiffs: StateDiff[] = [
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
  const enumerationIndexSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(4), 1);
  await setResult(
    "Compressor",
    "verifyCompressedStateDiffs",
    [stateDiffs.length, 4, encodedStateDiffs, compressedStateDiffs],
    {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["bytes32"], [ethers.utils.keccak256(encodedStateDiffs)]),
    }
  );
  const numberOfStateDiffsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(stateDiffs.length), 4);
  const compressedStateDiffsSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(ethers.utils.arrayify(compressedStateDiffs).length), 3);
  return {
    encodedStateDiffs,
    compressedStateDiffs,
    enumerationIndexSizeBytes,
    numberOfStateDiffsBytes,
    compressedStateDiffsSizeBytes,
  };
}

// LOG 
interface LogData {
  isService: boolean;
  key: Buffer;
  value: Buffer;
  message: Buffer;
  currentMessageLengthBytes: string;
}

function setupLogData(): LogData {
  return {
    isService: true,
    key: Buffer.alloc(32, 1),
    value: Buffer.alloc(32, 2),
    message: Buffer.alloc(32, 3),
    currentMessageLengthBytes: ethers.utils.hexZeroPad(ethers.utils.hexlify(32), 4),
  }
}

function createLogs(l1MessengerAccount: any, l1Messenger: any, logData: LogData): string[] {
  const firstLog = ethers.utils.concat([
    ethers.utils.hexlify([0]),
    ethers.utils.hexlify(1),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 2),
    ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
    logData.key,
    logData.value,
  ]);
  const secondLog = ethers.utils.concat([
    ethers.utils.hexlify([0]),
    ethers.utils.hexlify(1),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 2),
    ethers.utils.hexZeroPad(l1Messenger.address, 20),
    ethers.utils.hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32).toLowerCase(),
    ethers.utils.keccak256(logData.message),
  ]);
  return [firstLog, secondLog];
}

// bytecode
interface BytecodeData {
  content: string;
  lengthBytes: string;
}

async function setupBytecodeData(l1MessengerAddress: string): Promise<BytecodeData> {
  const content = await getCode(l1MessengerAddress);
  const lengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(ethers.utils.arrayify(content).length), 4);
  return {
    content,
    lengthBytes
  };
}
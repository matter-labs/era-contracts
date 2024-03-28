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
  let stateDiffsSetupData: StateDiffSetupData;
  let logData: LogData;
  let bytecodeData: ContentLengthPair;
  let emulator: L1MessengerPubdataEmulator;

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
    logData = setupLogData(l1MessengerAccount, l1Messenger);
    bytecodeData = await setupBytecodeData(ethers.constants.AddressZero);
    await setResult("SystemContext", "txNumberInBlock", [], {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [1]),
    });
    emulator = new L1MessengerPubdataEmulator();
  });

  after(async () => {
    // cleaning the state of l1Messenger
    await l1Messenger
      .connect(bootloaderAccount)
      .publishPubdataAndClearState(emulator.buildTotalL2ToL1PubdataAndStateDiffs());
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
      await (
        await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(logData.isService, logData.key, logData.value)
      ).wait();
      emulator.addLog(logData.logs[0].log);
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(logData.messages[0].message)).wait();
      emulator.addLog(logData.messages[0].log);
      emulator.addMessage({
        lengthBytes: logData.messages[0].currentMessageLengthBytes,
        content: logData.messages[0].message,
      });
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(await ethers.utils.hexlify(utils.hashBytecode(bytecodeData.content)), {
            gasLimit: 130000000,
          })
      ).wait();
      emulator.addBytecode(bytecodeData);
      emulator.setStateDiffsSetupData(stateDiffsSetupData);
      await (
        await l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(emulator.buildTotalL2ToL1PubdataAndStateDiffs(), { gasLimit: 1000000000 })
      ).wait();
    });

    it("should revert Too many L2->L1 logs", async () => {
      // set numberOfLogsBytes to 0x4002 to trigger the revert (max value is 0x4000)
      await expect(
        l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(emulator.buildTotalL2ToL1PubdataAndStateDiffs({ numberOfLogs: 0x4002 }))
      ).to.be.rejectedWith("Too many L2->L1 logs");
    });

    it("should revert logshashes mismatch", async () => {
      await (
        await l1Messenger.connect(l1MessengerAccount).sendL2ToL1Log(logData.isService, logData.key, logData.value)
      ).wait();
      await (await l1Messenger.connect(l1MessengerAccount).sendToL1(logData.messages[0].message)).wait();
      // set secondlog hash to random data to trigger the revert
      const overrideData = { encodedLogs: [...emulator.encodedLogs] };
      overrideData.encodedLogs[1] = encodeL2ToL1Log({
        l2ShardId: 0,
        isService: true,
        txNumberInBlock: 1,
        sender: l1Messenger.address,
        key: ethers.utils.hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32).toLowerCase(),
        value: ethers.utils.hexlify(randomBytes(32)),
      });
      await expect(
        l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(emulator.buildTotalL2ToL1PubdataAndStateDiffs(overrideData))
      ).to.be.rejectedWith("reconstructedChainedLogsHash is not equal to chainedLogsHash");
    });

    it("should revert chainedMessageHash mismatch", async () => {
      // Buffer.alloc(32, 6), to trigger the revert
      const wrongMessage = { lengthBytes: logData.messages[0].currentMessageLengthBytes, content: Buffer.alloc(32, 6) };
      const overrideData = { messages: [...emulator.messages] };
      overrideData.messages[0] = wrongMessage;
      await expect(
        l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(emulator.buildTotalL2ToL1PubdataAndStateDiffs(overrideData))
      ).to.be.rejectedWith("reconstructedChainedMessagesHash is not equal to chainedMessagesHash");
    });

    it("should revert state diff compression version mismatch", async () => {
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(await ethers.utils.hexlify(utils.hashBytecode(bytecodeData.content)), {
            gasLimit: 130000000,
          })
      ).wait();
      // modify version to trigger the revert
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(
          emulator.buildTotalL2ToL1PubdataAndStateDiffs({
            version: ethers.utils.hexZeroPad(ethers.utils.hexlify(66), 1),
          })
        )
      ).to.be.rejectedWith("state diff compression version mismatch");
    });

    it("should revert extra data", async () => {
      // add extra data to trigger the revert
      await expect(
        l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(
            ethers.utils.concat([emulator.buildTotalL2ToL1PubdataAndStateDiffs(), Buffer.alloc(1, 64)])
          )
      ).to.be.rejectedWith("Extra data in the totalL2ToL1Pubdata array");
    });
  });

  describe("sendL2ToL1Log", async () => {
    it("should revert when not called by the system contract", async () => {
      await expect(l1Messenger.sendL2ToL1Log(true, logData.key, logData.value)).to.be.rejectedWith(
        "This method require the caller to be system contract"
      );
    });

    it("should emit L2ToL1LogSent event when called by the system contract", async () => {
      await expect(
        l1Messenger
          .connect(l1MessengerAccount)
          .sendL2ToL1Log(true, ethers.utils.hexlify(logData.key), ethers.utils.hexlify(logData.value))
      )
        .to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([
          0,
          true,
          1,
          l1MessengerAccount.address,
          ethers.utils.hexlify(logData.key),
          ethers.utils.hexlify(logData.value),
        ]);
      emulator.addLog(logData.logs[0].log);
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
      emulator.addLog(
        encodeL2ToL1Log({
          l2ShardId: 0,
          isService: false,
          txNumberInBlock: 1,
          sender: l1MessengerAccount.address,
          key: logData.key,
          value: logData.value,
        })
      );
    });
  });

  describe("sendToL1", async () => {
    it("should emit L1MessageSent & L2ToL1LogSent events", async () => {
      const expectedKey = ethers.utils
        .hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32)
        .toLowerCase();
      await expect(l1Messenger.connect(l1MessengerAccount).sendToL1(logData.messages[0].message))
        .to.emit(l1Messenger, "L1MessageSent")
        .withArgs(
          l1MessengerAccount.address,
          ethers.utils.keccak256(logData.messages[0].message),
          logData.messages[0].message
        )
        .and.to.emit(l1Messenger, "L2ToL1LogSent")
        .withArgs([0, true, 1, l1Messenger.address, expectedKey, ethers.utils.keccak256(logData.messages[0].message)]);
      emulator.addLog(logData.messages[0].log);
      emulator.addMessage({
        lengthBytes: logData.messages[0].currentMessageLengthBytes,
        content: logData.messages[0].message,
      });
    });
  });

  describe("requestBytecodeL1Publication", async () => {
    it("should revert when not called by known code storage contract", async () => {
      const byteCodeHash = ethers.utils.hexlify(randomBytes(32));
      await expect(l1Messenger.requestBytecodeL1Publication(byteCodeHash)).to.be.rejectedWith("Inappropriate caller");
    });

    it("should emit event, called by known code system contract", async () => {
      await expect(
        l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(await ethers.utils.hexlify(utils.hashBytecode(bytecodeData.content)), {
            gasLimit: 130000000,
          })
      )
        .to.emit(l1Messenger, "BytecodeL1PublicationRequested")
        .withArgs(await ethers.utils.hexlify(utils.hashBytecode(bytecodeData.content)));
      emulator.addBytecode(bytecodeData);
    });
  });
});

// Interface represents the structure of the data that that is used in totalL2ToL1PubdataAndStateDiffs.
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
  const compressedStateDiffsSizeBytes = ethers.utils.hexZeroPad(
    ethers.utils.hexlify(ethers.utils.arrayify(compressedStateDiffs).length),
    3
  );
  return {
    encodedStateDiffs,
    compressedStateDiffs,
    enumerationIndexSizeBytes,
    numberOfStateDiffsBytes,
    compressedStateDiffsSizeBytes,
  };
}

// Interface for L2ToL1Log struct.
interface L2ToL1Log {
  l2ShardId: number;
  isService: boolean;
  txNumberInBlock: number;
  sender: string;
  key: Buffer;
  value: Buffer;
}

// Function to encode L2ToL1Log struct.
function encodeL2ToL1Log(log: L2ToL1Log): string {
  return ethers.utils.concat([
    ethers.utils.hexlify([log.l2ShardId]),
    ethers.utils.hexlify(log.isService ? 1 : 0),
    ethers.utils.hexZeroPad(ethers.utils.hexlify(log.txNumberInBlock), 2),
    ethers.utils.hexZeroPad(log.sender, 20),
    log.key,
    log.value,
  ]);
}

interface LogInfo {
  log: string;
}

interface MessageInfo extends LogInfo {
  message: string;
  currentMessageLengthBytes: string;
}

// The LogData interface represents the structure of the data that will be logged.
interface LogData {
  isService: boolean;
  key: Buffer;
  value: Buffer;
  messages: MessageInfo[];
  logs: LogInfo[];
}

function setupLogData(l1MessengerAccount: ethers.Signer, l1Messenger: L1Messenger): LogData {
  const key = Buffer.alloc(32, 1);
  const value = Buffer.alloc(32, 2);
  const message = Buffer.alloc(32, 3);
  const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(32), 4);
  const logs: LogInfo[] = [
    {
      log: encodeL2ToL1Log({
        l2ShardId: 0,
        isService: true,
        txNumberInBlock: 1,
        sender: l1MessengerAccount.address,
        key,
        value,
      }),
    },
  ];

  const messages: MessageInfo[] = [
    {
      message,
      currentMessageLengthBytes,
      log: encodeL2ToL1Log({
        l2ShardId: 0,
        isService: true,
        txNumberInBlock: 1,
        sender: l1Messenger.address,
        key: ethers.utils.hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32).toLowerCase(),
        value: ethers.utils.keccak256(message),
      }),
    },
  ];

  return {
    isService: true,
    key,
    value,
    messages,
    logs,
  };
}

// Represents the structure of the bytecode/message data that is part of the pubdata.
interface ContentLengthPair {
  content: string;
  lengthBytes: string;
}

async function setupBytecodeData(l1MessengerAddress: string): Promise<ContentLengthPair> {
  const content = await getCode(l1MessengerAddress);
  const lengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(ethers.utils.arrayify(content).length), 4);
  return {
    content,
    lengthBytes,
  };
}

// Used for emulating the pubdata published by the L1Messenger.
class L1MessengerPubdataEmulator implements EmulatorData {
  numberOfLogs: number;
  encodedLogs: string[];
  numberOfMessages: number;
  messages: ContentLengthPair[];
  numberOfBytecodes: number;
  bytecodes: ContentLengthPair[];
  stateDiffsSetupData: StateDiffSetupData;
  version: string;

  constructor() {
    this.numberOfLogs = 0;
    this.encodedLogs = [];
    this.numberOfMessages = 0;
    this.messages = [];
    this.numberOfBytecodes = 0;
    this.bytecodes = [];
    this.stateDiffsSetupData = {
      compressedStateDiffsSizeBytes: "",
      enumerationIndexSizeBytes: "",
      compressedStateDiffs: "",
      numberOfStateDiffsBytes: "",
      encodedStateDiffs: "",
    };
    this.version = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 1);
  }

  addLog(log: string): void {
    this.encodedLogs.push(log);
    this.numberOfLogs++;
  }

  addMessage(message: ContentLengthPair): void {
    this.messages.push(message);
    this.numberOfMessages++;
  }

  addBytecode(bytecode: ContentLengthPair): void {
    this.bytecodes.push(bytecode);
    this.numberOfBytecodes++;
  }

  setStateDiffsSetupData(data: StateDiffSetupData) {
    this.stateDiffsSetupData = data;
  }

  buildTotalL2ToL1PubdataAndStateDiffs(overrideData: EmulatorOverrideData = {}): string {
    const {
      numberOfLogs = this.numberOfLogs,
      encodedLogs = this.encodedLogs,
      numberOfMessages = this.numberOfMessages,
      messages = this.messages,
      numberOfBytecodes = this.numberOfBytecodes,
      bytecodes = this.bytecodes,
      stateDiffsSetupData = this.stateDiffsSetupData,
      version = this.version,
    } = overrideData;

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
      ...encodedLogs,
      ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4),
      ...messagePairs,
      ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4),
      ...bytecodePairs,
      version,
      stateDiffsSetupData.compressedStateDiffsSizeBytes,
      stateDiffsSetupData.enumerationIndexSizeBytes,
      stateDiffsSetupData.compressedStateDiffs,
      stateDiffsSetupData.numberOfStateDiffsBytes,
      stateDiffsSetupData.encodedStateDiffs,
    ]);
  }
}
// Represents the structure of the data that the emulator uses.
interface EmulatorData {
  numberOfLogs: number;
  encodedLogs: string[];
  numberOfMessages: number;
  messages: ContentLengthPair[];
  numberOfBytecodes: number;
  bytecodes: ContentLengthPair[];
  stateDiffsSetupData: StateDiffSetupData;
  version: string;
}

// Represents a type that allows for overriding specific properties of the EmulatorData.
// This is useful when you want to change some properties of the emulator data without affecting the others.
type EmulatorOverrideData = Partial<EmulatorData>;

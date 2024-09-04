import { ethers, network } from "hardhat";
import type { L1Messenger } from "../typechain";
import { IL2DAValidatorFactory } from "../typechain/IL2DAValidatorFactory";
import { L1MessengerFactory } from "../typechain";
import { prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getCode, getWallets } from "./shared/utils";
import { utils, L2VoidSigner } from "zksync-ethers";
import type { Wallet } from "zksync-ethers";
import {
  TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
  TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
  TEST_BOOTLOADER_FORMAL_ADDRESS,
} from "./shared/constants";
import { expect } from "chai";
import { randomBytes } from "crypto";

const EXPECTED_DA_INPUT_OFFSET = 160;
const L2_TO_L1_LOGS_MERKLE_TREE_LEAVES = 16_384;
const L2_TO_L1_LOG_SERIALIZE_SIZE = 88;
const L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH = "0x72abee45b59e344af8a6e520241c4744aff26ed411f4c4b00f8af09adada43ba";

describe("L1Messenger tests", () => {
  let l1Messenger: L1Messenger;
  let wallet: Wallet;
  let l1MessengerAccount: ethers.Signer;
  let knownCodeStorageAccount: ethers.Signer;
  let bootloaderAccount: ethers.Signer;
  let logData: LogData;
  let emulator: L1MessengerPubdataEmulator;
  let bytecode;

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, "L1Messenger");
    l1Messenger = L1MessengerFactory.connect(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, wallet);
    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
    knownCodeStorageAccount = await ethers.getImpersonatedSigner(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    // setup
    logData = setupLogData(l1MessengerAccount, l1Messenger);
    bytecode = await getCode(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
    await setResult("SystemContext", "txNumberInBlock", [], {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["uint16"], [1]),
    });
    await setResult("IMessageRoot", "getAggregatedRoot", [], {
      failure: false,
      returnData: ethers.constants.HashZero,
    });
    emulator = new L1MessengerPubdataEmulator();
  });

  after(async () => {
    // cleaning the state of l1Messenger
    await l1Messenger
      .connect(bootloaderAccount)
      .publishPubdataAndClearState(
        ethers.constants.AddressZero,
        await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger)
      );
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

      await (
        await l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(
            ethers.constants.AddressZero,
            await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger),
            { gasLimit: 1000000000 }
          )
      ).wait();
    });

    it("should revert Too many L2->L1 logs", async () => {
      // set numberOfLogsBytes to 0x4002 to trigger the revert (max value is 0x4000)
      await expect(
        l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(
            ethers.constants.AddressZero,
            await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, { numberOfLogs: 0x4002 })
          )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    });

    it("should revert Invalid input DA signature", async () => {
      await expect(
        l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(
            ethers.constants.AddressZero,
            await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, { l2DaValidatorFunctionSig: "0x12121212" })
          )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
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
          .publishPubdataAndClearState(
            ethers.constants.AddressZero,
            await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, overrideData)
          )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    });

    it("should revert Invalid input msgs hash", async () => {
      const correctChainedMessagesHash = await l1Messenger.provider.getStorageAt(l1Messenger.address, 2);

      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(
          ethers.constants.AddressZero,
          await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, {
            chainedMessagesHash: ethers.utils.keccak256(correctChainedMessagesHash),
          })
        )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    });

    it("should revert Invalid bytecodes hash", async () => {
      const correctChainedBytecodesHash = await l1Messenger.provider.getStorageAt(l1Messenger.address, 3);

      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(
          ethers.constants.AddressZero,
          await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, {
            chainedBytecodeHash: ethers.utils.keccak256(correctChainedBytecodesHash),
          })
        )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    });

    it("should revert Invalid offset", async () => {
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(
          ethers.constants.AddressZero,
          await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, {
            operatorDataOffset: EXPECTED_DA_INPUT_OFFSET + 1,
          })
        )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    });

    it("should revert Invalid length", async () => {
      await expect(
        l1Messenger
          .connect(bootloaderAccount)
          .publishPubdataAndClearState(
            ethers.constants.AddressZero,
            await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, { operatorDataLength: 1 })
          )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    });

    it("should revert Invalid root hash", async () => {
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(
          ethers.constants.AddressZero,
          await emulator.buildTotalL2ToL1PubdataAndStateDiffs(l1Messenger, {
            chainedLogsRootHash: ethers.constants.HashZero,
          })
        )
      ).to.be.revertedWithCustomError(l1Messenger, "ReconstructionMismatch");
    });
  });

  describe("sendL2ToL1Log", async () => {
    it("should revert when not called by the system contract", async () => {
      await expect(l1Messenger.sendL2ToL1Log(true, logData.key, logData.value)).to.be.revertedWithCustomError(
        l1Messenger,
        "CallerMustBeSystemContract"
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
    });
  });

  describe("requestBytecodeL1Publication", async () => {
    it("should revert when not called by known code storage contract", async () => {
      const byteCodeHash = ethers.utils.hexlify(randomBytes(32));
      await expect(l1Messenger.requestBytecodeL1Publication(byteCodeHash)).to.be.revertedWithCustomError(
        l1Messenger,
        "Unauthorized"
      );
    });

    it("should emit event, called by known code system contract", async () => {
      await expect(
        l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(ethers.utils.hexlify(utils.hashBytecode(bytecode)), {
            gasLimit: 230000000,
          })
      )
        .to.emit(l1Messenger, "BytecodeL1PublicationRequested")
        .withArgs(ethers.utils.hexlify(utils.hashBytecode(bytecode)));
    });
  });
});

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

// Used for emulating the pubdata published by the L1Messenger.
class L1MessengerPubdataEmulator implements EmulatorData {
  numberOfLogs: number;
  encodedLogs: string[];
  l2DaValidatorFunctionSig: string;
  chainedLogsHash: string;
  chainedLogsRootHash: string;
  operatorDataOffset: number;
  operatorDataLength: number;

  // These two fields are always zero, we need
  // them just to extend the interface.
  chainedMessagesHash: string;
  chainedBytecodeHash: string;

  constructor() {
    this.numberOfLogs = 0;
    this.encodedLogs = [];

    const factoryInterface = IL2DAValidatorFactory.connect(
      ethers.constants.AddressZero,
      new L2VoidSigner(ethers.constants.AddressZero)
    );
    this.l2DaValidatorFunctionSig = factoryInterface.interface.getSighash("validatePubdata");

    this.chainedLogsHash = ethers.constants.HashZero;
    this.chainedLogsRootHash = ethers.constants.HashZero;
    this.operatorDataOffset = EXPECTED_DA_INPUT_OFFSET;
  }

  addLog(log: string): void {
    this.encodedLogs.push(log);
    this.numberOfLogs++;
  }

  async buildTotalL2ToL1PubdataAndStateDiffs(
    l1Messenger: L1Messenger,
    overrideData: EmulatorOverrideData = {}
  ): Promise<string> {
    const storedChainedMessagesHash = await l1Messenger.provider.getStorageAt(l1Messenger.address, 2);
    const storedChainedBytecodesHash = await l1Messenger.provider.getStorageAt(l1Messenger.address, 3);

    const {
      l2DaValidatorFunctionSig = this.l2DaValidatorFunctionSig,
      chainedLogsHash = calculateChainedLogsHash(this.encodedLogs),
      chainedLogsRootHash = calculateLogsRootHash(this.encodedLogs),
      chainedMessagesHash = storedChainedMessagesHash,
      chainedBytecodeHash = storedChainedBytecodesHash,
      operatorDataOffset = this.operatorDataOffset,
      numberOfLogs = this.numberOfLogs,
      encodedLogs = this.encodedLogs,
    } = overrideData;
    const operatorDataLength = overrideData.operatorDataLength
      ? overrideData.operatorDataLength
      : numberOfLogs * L2_TO_L1_LOG_SERIALIZE_SIZE + 4;

    return ethers.utils.concat([
      l2DaValidatorFunctionSig,
      chainedLogsHash,
      chainedLogsRootHash,
      chainedMessagesHash,
      chainedBytecodeHash,
      ethers.utils.defaultAbiCoder.encode(["uint256"], [operatorDataOffset]),
      ethers.utils.defaultAbiCoder.encode(["uint256"], [operatorDataLength]),
      ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4),
      ...encodedLogs,
    ]);
  }
}
// Represents the structure of the data that the emulator uses.
interface EmulatorData {
  l2DaValidatorFunctionSig: string;
  chainedLogsHash: string;
  chainedLogsRootHash: string;
  chainedMessagesHash: string;
  chainedBytecodeHash: string;
  operatorDataOffset: number;
  operatorDataLength: number;
  numberOfLogs: number;
  encodedLogs: string[];
}

// Represents a type that allows for overriding specific properties of the EmulatorData.
// This is useful when you want to change some properties of the emulator data without affecting the others.
type EmulatorOverrideData = Partial<EmulatorData>;

function calculateChainedLogsHash(logs: string[]): string {
  let hash = ethers.constants.HashZero;
  for (const log of logs) {
    const logHash = ethers.utils.keccak256(log);
    hash = ethers.utils.keccak256(ethers.utils.concat([hash, logHash]));
  }

  return hash;
}

function calculateLogsRootHash(logs: string[]): string {
  const logsTreeArray: string[] = new Array(L2_TO_L1_LOGS_MERKLE_TREE_LEAVES).fill(L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH);
  for (let i = 0; i < logs.length; i++) {
    logsTreeArray[i] = ethers.utils.keccak256(logs[i]);
  }

  let length = L2_TO_L1_LOGS_MERKLE_TREE_LEAVES;

  while (length > 1) {
    for (let i = 0; i < length; i += 2) {
      logsTreeArray[i / 2] = ethers.utils.keccak256(ethers.utils.concat([logsTreeArray[i], logsTreeArray[i + 1]]));
    }
    length /= 2;
  }
  return logsTreeArray[0];
}

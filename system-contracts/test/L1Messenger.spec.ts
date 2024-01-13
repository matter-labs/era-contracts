import { ethers, network } from "hardhat";
import type { L1Messenger } from "../typechain";
import { L1MessengerFactory } from "../typechain";
import { prepareEnvironment, setResult } from "./shared/mocks";
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

  before(async () => {
    await prepareEnvironment();
    wallet = getWallets()[0];
    await deployContractOnAddress(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, "L1Messenger");
    l1Messenger = L1MessengerFactory.connect(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, wallet);
    l1MessengerAccount = await ethers.getImpersonatedSigner(TEST_L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
    knownCodeStorageAccount = await ethers.getImpersonatedSigner(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
  });

  // this part is necessary to clean the state of L1Messenger contract
  after(async () => {
    const isService = true;
    const key = Buffer.alloc(32, 1);
    const value = Buffer.alloc(32, 2);
    const txNumberInBlock = 1;
    const firstLog = ethers.utils.concat([
      ethers.utils.hexlify([0]),
      ethers.utils.hexlify([isService ? 1 : 0]),
      ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
      ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
      key,
      value,
    ]);

    const message = Buffer.alloc(32, 3);
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

    const bytecode = await getCode(l1Messenger.address);
    const lengthOfBytecode = ethers.utils.arrayify(bytecode).length;

    const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
    const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

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

    const version = ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 1);
    const compressedStateDiffsBuffer = ethers.utils.arrayify(compressedStateDiffs);
    const compressedStateDiffsLength = compressedStateDiffsBuffer.length;
    const compressedStateDiffsSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(compressedStateDiffsLength), 3);
    const enumerationIndexSizeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(enumerationIndexSize), 1);
    const numberOfStateDiffsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfStateDiffs), 4);

    // third log from test case: "sendL2ToL1Log" ->
    // "should emit L2ToL1LogSent event when called by the system contract"
    const thirdLog = ethers.utils.concat([
      ethers.utils.hexlify([0]),
      ethers.utils.hexlify([isService ? 1 : 0]),
      ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
      ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
      key,
      value,
    ]);
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
    const fifthLog = ethers.utils.concat([
      ethers.utils.hexlify([0]),
      ethers.utils.hexlify([isService ? 1 : 0]),
      ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
      ethers.utils.hexZeroPad(l1Messenger.address, 20),
      senderAddress,
      messageHash,
    ]);
    numberOfLogs++;
    numberOfMessages++;

    // 1 more bytecde from test case: "requestBytecodeL1Publication"
    numberOfBytecodes++;

    const numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
    const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
    const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
    const totalL2ToL1PubdataAndStateDiffs = ethers.utils.concat([
      numberOfLogsBytes,
      firstLog,
      secondLog,
      thirdLog,
      fourthLog,
      fifthLog,
      numberOfMessagesBytes,
      currentMessageLengthBytes,
      message,
      currentMessageLengthBytes,
      message,
      numberOfBytecodesBytes,
      lengthOfBytecodeBytes,
      bytecode,
      lengthOfBytecodeBytes,
      bytecode,
      version,
      compressedStateDiffsSizeBytes,
      enumerationIndexSizeBytes,
      compressedStateDiffs,
      numberOfStateDiffsBytes,
      encodedStateDiffs,
    ]);
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
      // ====================================================================================================
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

      const bytecode = await getCode(l1Messenger.address);
      const bytecodeHash = await ethers.utils.hexlify(utils.hashBytecode(bytecode));
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(bytecodeHash, { gasLimit: 130000000 })
      ).wait();
      numberOfBytecodes++;
      const lengthOfBytecode = ethers.utils.arrayify(bytecode).length;

      // ====================================================================================================
      // Prepare data for publishPubdataAndClearState()
      const numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
      const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
      const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
      const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
      const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

      // ====================================================================================================
      // Prepare state diffs
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

      const bytecode = await getCode(l1Messenger.address);
      const bytecodeHash = await ethers.utils.hexlify(utils.hashBytecode(bytecode));
      await (
        await l1Messenger
          .connect(knownCodeStorageAccount)
          .requestBytecodeL1Publication(bytecodeHash, { gasLimit: 130000000 })
      ).wait();
      numberOfBytecodes++;
      const lengthOfBytecode = ethers.utils.arrayify(bytecode).length;

      // ====================================================================================================
      // Prepare data for publishPubdataAndClearState()
      let numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
      const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
      const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
      const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
      const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

      // ====================================================================================================
      // Prepare state diffs
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
    });

    it("should revert logshashes mismatch", async () => {
      // ====================================================================================================
      const isService = true;
      const key = Buffer.alloc(32, 1);
      const value = Buffer.alloc(32, 2);
      const txNumberInBlock = 1;
      const firstLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
        key,
        value,
      ]);

      // ==================================================================================================== -- wrong messageHash, incorrect logshahs
      const message = Buffer.alloc(32, 3);
      const senderAddress = ethers.utils
        .hexZeroPad(ethers.utils.hexStripZeros(l1MessengerAccount.address), 32)
        .toLowerCase();
      const secondLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1Messenger.address, 20),
        senderAddress,
        ethers.utils.hexlify(randomBytes(32)),
      ]);
      const currentMessageLength = 32;
      // ====================================================================================================

      const bytecode = await getCode(l1Messenger.address);
      const lengthOfBytecode = ethers.utils.arrayify(bytecode).length;

      // ====================================================================================================
      // Prepare data for publishPubdataAndClearState()
      const numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
      const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
      const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
      const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
      const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

      // ====================================================================================================
      // Prepare state diffs
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
      // set firstLog to random data to trigger the revert (max value is 0x800)
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
      ).to.be.rejectedWith("reconstructedChainedLogsHash is not equal to chainedLogsHash");
    });

    it("should revert chainedMessageHash mismatch", async () => {
      // ====================================================================================================
      const isService = true;
      const key = Buffer.alloc(32, 1);
      const value = Buffer.alloc(32, 2);
      const txNumberInBlock = 1;
      const firstLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
        key,
        value,
      ]);

      // ====================================================================================================
      const message = Buffer.alloc(32, 3);
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

      // ====================================================================================================

      const bytecode = await getCode(l1Messenger.address);
      const lengthOfBytecode = ethers.utils.arrayify(bytecode).length;

      // ====================================================================================================
      // Prepare data for publishPubdataAndClearState()
      const numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
      const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
      const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
      const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
      const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

      // ====================================================================================================
      // Prepare state diffs
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
      // messageHash = Buffer.alloc(32, 6), to trigger the revert
      const totalL2ToL1PubdataAndStateDiffs = ethers.utils.concat([
        numberOfLogsBytes,
        firstLog,
        secondLog,
        numberOfMessagesBytes,
        currentMessageLengthBytes,
        Buffer.alloc(32, 6),
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
      ).to.be.rejectedWith("reconstructedChainedMessagesHash is not equal to chainedMessagesHash");
    });

    it("should revert state diff compression version mismatch", async () => {
      // ====================================================================================================
      const isService = true;
      const key = Buffer.alloc(32, 1);
      const value = Buffer.alloc(32, 2);
      const txNumberInBlock = 1;
      const firstLog = ethers.utils.concat([
        ethers.utils.hexlify([0]),
        ethers.utils.hexlify([isService ? 1 : 0]),
        ethers.utils.hexZeroPad(ethers.utils.hexlify(txNumberInBlock), 2),
        ethers.utils.hexZeroPad(l1MessengerAccount.address, 20),
        key,
        value,
      ]);

      // ====================================================================================================
      const message = Buffer.alloc(32, 3);

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

      // ====================================================================================================

      const bytecode = await getCode(l1Messenger.address);
      const lengthOfBytecode = ethers.utils.arrayify(bytecode).length;

      // ====================================================================================================
      // Prepare data for publishPubdataAndClearState()
      const numberOfLogsBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfLogs), 4);
      const numberOfMessagesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfMessages), 4);
      const currentMessageLengthBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(currentMessageLength), 4);
      const numberOfBytecodesBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(numberOfBytecodes), 4);
      const lengthOfBytecodeBytes = ethers.utils.hexZeroPad(ethers.utils.hexlify(lengthOfBytecode), 4);

      // ====================================================================================================
      // Prepare state diffs
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
      // modify version to trigger the revert
      const version = ethers.utils.hexZeroPad(ethers.utils.hexlify(111), 1);
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
      await expect(
        l1Messenger.connect(bootloaderAccount).publishPubdataAndClearState(totalL2ToL1PubdataAndStateDiffs)
      ).to.be.rejectedWith("state diff compression version mismatch");
    });
  });

  describe("sendL2ToL1Log", async () => {
    it("should revert when not called by the system contract", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(randomBytes(32));
      const value = ethers.utils.hexlify(randomBytes(32));
      await expect(l1Messenger.sendL2ToL1Log(isService, key, value)).to.be.rejectedWith(
        "This method require the caller to be system contract"
      );
    });

    it("should emit L2ToL1LogSent event when called by the system contract", async () => {
      const isService = true;
      const key = ethers.utils.hexlify(Buffer.alloc(32, 1));
      const value = ethers.utils.hexlify(Buffer.alloc(32, 2));

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
      const key = ethers.utils.hexlify(Buffer.alloc(32, 1));
      const value = ethers.utils.hexlify(Buffer.alloc(32, 2));

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
      const message = ethers.utils.hexlify(Buffer.alloc(32, 3));
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
});

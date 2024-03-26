import { ethers, network } from "hardhat";
import { SystemContextFactory } from "../typechain";
import type { SystemContext } from "../typechain";
import { TEST_BOOTLOADER_FORMAL_ADDRESS, TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS } from "./shared/constants";
import { deployContractOnAddress, getWallets } from "./shared/utils";
import { prepareEnvironment } from "./shared/mocks";
import { expect } from "chai";

describe("SystemContext tests", () => {
  const wallet = getWallets()[0];
  let systemContext: SystemContext;
  let bootloaderAccount: ethers.Signer;

  before(async () => {
    await prepareEnvironment();
    await deployContractOnAddress(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS, "SystemContext");
    systemContext = SystemContextFactory.connect(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS, wallet);
    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
  });

  after(async function () {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
    });
  });

  describe("setTxOrigin", async () => {
    it("should revert not called by bootlader", async () => {
      const txOriginExpected = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
      await expect(systemContext.setTxOrigin(txOriginExpected)).to.be.rejectedWith("Callable only by the bootloader");
    });

    it("should set tx.origin", async () => {
      const txOriginBefore = await systemContext.origin();
      const txOriginExpected = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";
      await systemContext.connect(bootloaderAccount).setTxOrigin(txOriginExpected);
      const result = (await systemContext.origin()).toLowerCase();
      expect(result).to.be.equal(txOriginExpected);
      expect(result).to.be.not.equal(txOriginBefore);
    });
  });

  describe("setGasPrice", async () => {
    it("should revert not called by bootlader", async () => {
      const newGasPrice = 4294967295;
      await expect(systemContext.setGasPrice(newGasPrice)).to.be.rejectedWith("Callable only by the bootloader");
    });

    it("should set tx.gasprice", async () => {
      const gasPriceBefore = await systemContext.gasPrice();
      const gasPriceExpected = 4294967295;
      await systemContext.connect(bootloaderAccount).setGasPrice(gasPriceExpected);
      const result = await systemContext.gasPrice();
      expect(result).to.be.equal(gasPriceExpected);
      expect(result).to.be.not.equal(gasPriceBefore);
    });
  });

  describe("getBatchNumberAndTimestamp", async () => {
    it("should get batch number and timestamp", async () => {
      const result = await systemContext.getBatchNumberAndTimestamp();
      expect(result.batchNumber).to.be.equal(0);
      expect(result.batchTimestamp).to.be.equal(0);
    });

    it("should get changed batch data", async () => {
      await systemContext.connect(bootloaderAccount).unsafeOverrideBatch(222, 111, 333);
      const batchDataAfterChanges = await systemContext.getBatchNumberAndTimestamp();
      const baseFee = await systemContext.baseFee();
      expect(batchDataAfterChanges.batchNumber).to.be.equal(111);
      expect(batchDataAfterChanges.batchTimestamp).to.be.equal(222);
      expect(baseFee).to.be.equal(333);
      await systemContext.connect(bootloaderAccount).unsafeOverrideBatch(0, 0, 0);
      const batchDataRestored = await systemContext.getBatchNumberAndTimestamp();
      const baseFeeRestored = await systemContext.baseFee();
      expect(batchDataRestored.batchNumber).to.be.equal(0);
      expect(batchDataRestored.batchTimestamp).to.be.equal(0);
      expect(baseFeeRestored).to.be.equal(0);
    });
  });

  describe("setNewBatch", async () => {
    it("should get hash of the given batch", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const result = await systemContext.getBatchHash(batchData.batchNumber);
      expect(result).to.equal(ethers.constants.HashZero);
    });

    it("should revert not called by bootlader", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      await expect(
        systemContext.setNewBatch(batchHash, batchData.batchTimestamp.add(1), batchData.batchNumber.add(1), 1)
      ).to.be.rejectedWith("Callable only by the bootloader");
    });

    it("should revert timestamp should be incremental", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setNewBatch(batchHash, batchData.batchTimestamp, batchData.batchNumber.add(1), 1)
      ).to.be.rejectedWith("Timestamps should be incremental");
    });

    it("should revert wrong block number", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setNewBatch(batchHash, batchData.batchTimestamp.add(1), batchData.batchNumber, 1)
      ).to.be.rejectedWith("The provided batch number is not correct");
    });

    it("should set new batch", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      const newBatchHash = await ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [2137]));
      await systemContext
        .connect(bootloaderAccount)
        .setNewBatch(newBatchHash, batchData.batchTimestamp.add(42), batchData.batchNumber.add(1), 2);
      const batchDataAfter = await systemContext.getBatchNumberAndTimestamp();
      expect(batchDataAfter.batchNumber).to.be.equal(batchData.batchNumber.add(1));
      expect(batchDataAfter.batchTimestamp).to.be.equal(batchData.batchTimestamp.add(42));
      const prevBatchHashAfter = await systemContext.getBatchHash(batchData.batchNumber);
      expect(prevBatchHashAfter).to.not.be.equal(batchHash);
      expect(prevBatchHashAfter).to.be.equal(newBatchHash);
    });
  });

  describe("setL2Block", async () => {
    it("should get current l2 block number and timestamp", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      expect(blockData.blockNumber).to.be.equal(0);
      expect(blockData.blockTimestamp).to.be.equal(0);
    });

    it("should get current l2 block number", async () => {
      const blockNumber = await systemContext.getBlockNumber();
      expect(blockNumber).to.be.equal(0);
    });

    it("should get current l2 block timestamp", async () => {
      const blockTimestamp = await systemContext.getBlockTimestamp();
      expect(blockTimestamp).to.be.equal(0);
    });

    it("should revert Callable only by the bootloader", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext.setL2Block(
          blockData.blockNumber.add(1),
          blockData.blockTimestamp.add(42),
          expectedBlockHash,
          true,
          1
        )
      ).to.be.rejectedWith("Callable only by the bootloader");
    });

    it("should revert The timestamp of the L2 block must be greater than or equal to the timestamp of the current batch", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), 0, expectedBlockHash, true, 1)
      ).to.be.rejectedWith(
        "The timestamp of the L2 block must be greater than or equal to the timestamp of the current batch"
      );
    });

    it("should revert There must be a virtual block created at the start of the batch", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(42), expectedBlockHash, true, 0)
      ).to.be.rejectedWith("There must be a virtual block created at the start of the batch");
    });

    it("should revert Upgrade transaction must be first", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(42), expectedBlockHash, false, 1)
      ).to.be.rejectedWith("Upgrade transaction must be first");
    });

    it("should revert L2 block number is never expected to be zero", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(0, blockData.blockTimestamp.add(42), expectedBlockHash, true, 1)
      ).to.be.rejectedWith("L2 block number is never expected to be zero");
    });

    it("should revert The previous L2 block hash is incorrect", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const wrongBlockHash = Buffer.alloc(32, 1);
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(42), wrongBlockHash, true, 1)
      ).to.be.rejectedWith("The previous L2 block hash is incorrect");
    });

    it("should set L2 block, check blockNumber & blockTimestamp change, also check getBlockHashEVM", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await systemContext
        .connect(bootloaderAccount)
        .setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(42), expectedBlockHash, true, 1);
      const blockDataAfter = await systemContext.getL2BlockNumberAndTimestamp();
      expect(blockDataAfter.blockNumber).to.be.equal(blockData.blockNumber.add(1));
      expect(blockDataAfter.blockTimestamp).to.be.equal(blockData.blockTimestamp.add(42));
      const blockNumber = await systemContext.getBlockNumber();
      const blockTimestamp = await systemContext.getBlockTimestamp();
      expect(blockNumber).to.be.equal(blockData.blockNumber.add(1));
      expect(blockTimestamp).to.be.equal(blockData.blockTimestamp.add(42));
      // getBlockHashEVM
      // blockNumber <= block
      const blockHash = await systemContext.getBlockHashEVM(blockData.blockNumber.add(100));
      expect(blockHash).to.be.equal(ethers.constants.HashZero);
      // block < currentVirtualBlockUpgradeInfo.virtualBlockStartBatch
      const blockHash1 = await systemContext.getBlockHashEVM(0);
      const batchHash = await systemContext.getBatchHash(0);
      expect(blockHash1).to.be.equal(batchHash);
    });

    it("should revert Can not reuse L2 block number from the previous batch", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber, blockData.blockTimestamp.add(42), expectedBlockHash, true, 1)
      ).to.be.rejectedWith("Can not reuse L2 block number from the previous batch");
    });

    it("should revert The timestamp of the same L2 block must be same", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber, blockData.blockTimestamp.add(42), expectedBlockHash, false, 1)
      ).to.be.rejectedWith("The timestamp of the same L2 block must be same");
    });

    it("should revert The previous hash of the same L2 block must be same", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(
        ethers.utils.solidityPack(["uint32"], [blockData.blockNumber.add(11)])
      );
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber, blockData.blockTimestamp, expectedBlockHash, false, 1)
      ).to.be.rejectedWith("The previous hash of the same L2 block must be same");
    });

    it("should revert Can not create virtual blocks in the middle of the miniblock", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(
        ethers.utils.solidityPack(["uint32"], [blockData.blockNumber.sub(1)])
      );
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber, blockData.blockTimestamp, expectedBlockHash, false, 1)
      ).to.be.rejectedWith("Can not create virtual blocks in the middle of the miniblock");
    });

    it("should set block again, no data changed", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(
        ethers.utils.solidityPack(["uint32"], [blockData.blockNumber.sub(1)])
      );
      await systemContext
        .connect(bootloaderAccount)
        .setL2Block(blockData.blockNumber, blockData.blockTimestamp, expectedBlockHash, false, 0);
      const blockDataAfter = await systemContext.getL2BlockNumberAndTimestamp();
      expect(blockDataAfter.blockNumber).to.be.equal(blockData.blockNumber);
      expect(blockDataAfter.blockTimestamp).to.be.equal(blockData.blockTimestamp);
    });

    it("should revert The current L2 block hash is incorrect", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const invalidBlockHash = ethers.utils.keccak256(
        ethers.utils.solidityPack(["uint32"], [blockData.blockNumber.add(11)])
      );
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(42), invalidBlockHash, false, 0)
      ).to.be.rejectedWith("The current L2 block hash is incorrect");
    });

    it("should revert The timestamp of the new L2 block must be greater than the timestamp of the previous L2 block", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const prevL2BlockHash = ethers.utils.keccak256(
        ethers.utils.solidityPack(["uint32"], [blockData.blockNumber.sub(1)])
      );
      const blockTxsRollingHash = ethers.utils.hexlify(Buffer.alloc(32, 0));
      const expectedBlockHash = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["uint128", "uint128", "bytes32", "bytes32"],
          [blockData.blockNumber, blockData.blockTimestamp, prevL2BlockHash, blockTxsRollingHash]
        )
      );
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber.add(1), 0, expectedBlockHash, false, 0)
      ).to.be.rejectedWith(
        "The timestamp of the new L2 block must be greater than the timestamp of the previous L2 block"
      );
    });

    it("should set block again and check blockNumber & blockTimestamp also check getBlockHashEVM", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const prevL2BlockHash = ethers.utils.keccak256(
        ethers.utils.solidityPack(["uint32"], [blockData.blockNumber.sub(1)])
      );
      const blockTxsRollingHash = ethers.utils.hexlify(Buffer.alloc(32, 0));
      const prevBlockHash = await systemContext.getBlockHashEVM(blockData.blockNumber);
      const expectedBlockHash = ethers.utils.keccak256(
        ethers.utils.defaultAbiCoder.encode(
          ["uint128", "uint128", "bytes32", "bytes32"],
          [blockData.blockNumber, blockData.blockTimestamp, prevL2BlockHash, blockTxsRollingHash]
        )
      );
      await systemContext
        .connect(bootloaderAccount)
        .setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(42), expectedBlockHash, false, 0);
      // check getBlockHashEVM; blockHashAfter = _getLatest257L2blockHash
      const blockHashAfter = await systemContext.getBlockHashEVM(blockData.blockNumber);
      const blockDataAfter = await systemContext.getL2BlockNumberAndTimestamp();
      expect(blockDataAfter.blockNumber).to.be.equal(blockData.blockNumber.add(1));
      expect(blockDataAfter.blockTimestamp).to.be.equal(blockData.blockTimestamp.add(42));
      expect(blockHashAfter).to.not.be.equal(prevBlockHash);
      expect(blockHashAfter).to.be.equal(expectedBlockHash);
    });

    it("should revert Invalid new L2 block number", async () => {
      const blockData = await systemContext.getL2BlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [blockData.blockNumber]));
      await expect(
        systemContext
          .connect(bootloaderAccount)
          .setL2Block(blockData.blockNumber.add(111), blockData.blockTimestamp.add(42), expectedBlockHash, false, 0)
      ).to.be.rejectedWith("Invalid new L2 block number");
    });

    it("should update currentL2BlockTxsRollingHash", async () => {
      const slot = 10;
      const before = await systemContext.provider.getStorageAt(systemContext.address, slot);

      const hash = ethers.utils.keccak256(ethers.utils.solidityPack(["uint32"], [111]));
      await systemContext.connect(bootloaderAccount).appendTransactionToCurrentL2Block(hash);

      const value = await systemContext.provider.getStorageAt(systemContext.address, slot);
      const cumulative = ethers.utils.keccak256(ethers.utils.solidityPack(["bytes32", "bytes32"], [before, hash]));
      expect(value).to.be.equal(cumulative);
    });
  });

  describe("publishTimestampDataToL1", async () => {
    it("should revert The current batch number must be greater than 0", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const baseFee = await systemContext.baseFee();
      await systemContext.connect(bootloaderAccount).unsafeOverrideBatch(batchData.batchTimestamp, 0, baseFee);
      await expect(systemContext.connect(bootloaderAccount).publishTimestampDataToL1()).to.be.rejectedWith(
        "The current batch number must be greater than 0"
      );
      await systemContext
        .connect(bootloaderAccount)
        .unsafeOverrideBatch(batchData.batchTimestamp, batchData.batchNumber, baseFee);
    });

    it("should publish timestamp data to L1", async () => {
      await systemContext.connect(bootloaderAccount).publishTimestampDataToL1();
    });
  });

  describe("incrementTxNumberInBatch", async () => {
    it("should increment tx number in batch", async () => {
      await systemContext.connect(bootloaderAccount).incrementTxNumberInBatch();
      expect(await systemContext.txNumberInBlock()).to.be.equal(1);
    });
  });

  describe("resetTxNumberInBatch", async () => {
    it("should reset tx number in batch", async () => {
      await systemContext.connect(bootloaderAccount).resetTxNumberInBatch();
      expect(await systemContext.txNumberInBlock()).to.be.equal(0);
    });
  });
});

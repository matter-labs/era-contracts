import { ethers, network } from "hardhat";
import { SystemContext } from "../typechain";
import { SystemContextFactory } from "../typechain";
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

  describe("getBlockNumber", async () => {
    it("get block number", async () => {
      const result = await systemContext.getBlockNumber();
      expect(result).to.be.equal(0);
    });
  });

  describe("getBlockHashEVM", async () => {
    it("should return current block hash", async () => {
      const blockNumber = await systemContext.getBlockNumber();
      const result = await systemContext.getBlockHashEVM(blockNumber);
      expect(result).to.equal(ethers.constants.HashZero);
    });
  });

  describe("getBatchHash", async () => {
    it("should get hash of the given batch", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const result = await systemContext.getBatchHash(batchData.batchNumber);
      expect(result).to.equal(ethers.constants.HashZero);
    });
  });

  describe("getBatchNumberAndTimestamp", async () => {
    it("should get batch number and timestamp", async () => {
      const result = await systemContext.getBatchNumberAndTimestamp();
      expect(result.batchNumber).to.be.equal(0);
      expect(result.batchTimestamp).to.be.equal(0);
    });
  });

  describe("getL2BlockNumberAndTimestamp", async () => {
    it("should get current l2 block number and timestamp", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      expect(blockData.blockNumber).to.be.equal(0);
      expect(blockData.blockTimestamp).to.be.equal(0);
    });
  });

  describe("getBlockNumber", async () => {
    it("should get current l2 block number", async () => {
      const blockNumber = await systemContext.getBlockNumber();
      expect(blockNumber).to.be.equal(0);
    });
  });

  describe("getBlockTimestamp", async () => {
    it("should get current l2 block timestamp", async () => {
      const blockTimestamp = await systemContext.getBlockTimestamp();
      expect(blockTimestamp).to.be.equal(0);
    });
  });

  describe("setNewBatch", async () => {
    it("should revert not called by bootlader", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      await expect(systemContext.setNewBatch(batchHash, batchData.batchTimestamp.add(1), batchData.batchNumber.add(1), 1)).to.be.rejectedWith("Callable only by the bootloader");
    });;

    it("should revert timestamp should be incremental", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      await expect(systemContext.connect(bootloaderAccount).setNewBatch(batchHash, batchData.batchTimestamp, batchData.batchNumber.add(1), 1)).to.be.rejectedWith("Timestamps should be incremental")
    });

    it("should revert wrong block number", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      await expect(systemContext.connect(bootloaderAccount).setNewBatch(batchHash, batchData.batchTimestamp.add(1), batchData.batchNumber, 1)).to.be.rejectedWith("The provided block number is not correct")
    });

    it("should set new batch", async () => {
      const batchData = await systemContext.getBatchNumberAndTimestamp();
      const batchHash = await systemContext.getBatchHash(batchData.batchNumber);
      await systemContext.connect(bootloaderAccount).setNewBatch(batchHash, batchData.batchTimestamp.add(1), batchData.batchNumber.add(1), 1);
      const batchDataAfter = await systemContext.getBatchNumberAndTimestamp();
      expect(batchDataAfter.batchNumber).to.be.equal(batchData.batchNumber.add(1));
      expect(batchDataAfter.batchTimestamp).to.be.equal(batchData.batchTimestamp.add(1));
    });
  })

  // TODO: add expects 
  describe("setL2Block", async () => {
    it("should revert Callable only by the bootloader", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, true, 1)).to.be.rejectedWith("Callable only by the bootloader");
    });

    it("should revert The timestamp of the L2 block must be greater than or equal to the timestamp of the current batch", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), 0, expectedBlockHash, true, 1))
      .to.be.rejectedWith("The timestamp of the L2 block must be greater than or equal to the timestamp of the current batch");
    });

    it("should revert There must be a virtual block created at the start of the batch", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, true, 0))
      .to.be.rejectedWith("There must be a virtual block created at the start of the batch");
    });

    it("should revert Upgrade transaction must be first", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, false, 1))
      .to.be.rejectedWith("Upgrade transaction must be first");
    });

    it("should revert L2 block number is never expected to be zero", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(0, blockData.blockTimestamp.add(1), expectedBlockHash, true, 1)).to.be.rejectedWith("L2 block number is never expected to be zero");
    });

    it("should revert The previous L2 block hash is incorrect", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = Buffer.alloc(32, 1)
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, true, 1)).to.be.rejectedWith("The previous L2 block hash is incorrect");
    })

    it("should set L2 block", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, true, 1);
    });

    it("should revert Can not reuse L2 block number from the previous batch", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, true, 1)).to.be.rejectedWith("Can not reuse L2 block number from the previous batch");
    });

    it("should revert The timestamp of the same L2 block must be same", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(111), expectedBlockHash, false, 1)).to.be.rejectedWith("The timestamp of the same L2 block must be same");
    });

    it("should revert The previous hash of the same L2 block must be same", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber.add(11)]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, false, 1)).to.be.rejectedWith("The previous hash of the same L2 block must be same");
    });

    it("should revert Can not create virtual blocks in the middle of the miniblock", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, false, 1)).to.be.rejectedWith("Can not create virtual blocks in the middle of the miniblock");
    });

    it("should set block again", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber]));
      await systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(1), blockData.blockTimestamp.add(1), expectedBlockHash, false, 0);
    });

    it("should revert The current L2 block hash is incorrect", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber.add(2)]));
      await expect(systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(2), blockData.blockTimestamp.add(1), expectedBlockHash, false, 0)).to.be.rejectedWith("The current L2 block hash is incorrect");
    });

    it("should set block again", async () => {
      const blockData = await systemContext.getBlockNumberAndTimestamp();
      const expectedBlockHash = ethers.utils.keccak256(ethers.utils.solidityPack(['uint32'], [blockData.blockNumber.add(2)]));
      await systemContext.connect(bootloaderAccount).setL2Block(blockData.blockNumber.add(2), blockData.blockTimestamp.add(1), expectedBlockHash, false, 0);
    });
  })
});

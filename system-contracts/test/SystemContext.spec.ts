import { ethers, network } from "hardhat";
import type { SystemContext } from "../typechain";
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
});

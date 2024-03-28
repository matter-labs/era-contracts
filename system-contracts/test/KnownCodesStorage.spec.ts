import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-ethers";
import type { KnownCodesStorage } from "../typechain";
import { KnownCodesStorageFactory } from "../typechain";
import {
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TEST_COMPRESSOR_CONTRACT_ADDRESS,
  TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS,
} from "./shared/constants";
import { encodeCalldata, getMock, prepareEnvironment } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";

describe("KnownCodesStorage tests", function () {
  let wallet: Wallet;
  let bootloaderAccount: ethers.Signer;
  let compressorAccount: ethers.Signer;

  let knownCodesStorage: KnownCodesStorage;

  const BYTECODE_HASH_1 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";
  const BYTECODE_HASH_2 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEE1";
  const BYTECODE_HASH_3 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEE2";
  const BYTECODE_HASH_4 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEE3";
  const INCORRECTLY_FORMATTED_HASH = "0x0120FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";
  const INVALID_LENGTH_HASH = "0x0100FFFEDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";

  // TODO: currently test depends on the previous state and can not be run twice, think about fixing it. Relevant for other tests as well.
  before(async () => {
    await prepareEnvironment();
    wallet = (await getWallets())[0];

    await deployContractOnAddress(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS, "KnownCodesStorage");
    knownCodesStorage = KnownCodesStorageFactory.connect(TEST_KNOWN_CODE_STORAGE_CONTRACT_ADDRESS, wallet);

    bootloaderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    compressorAccount = await ethers.getImpersonatedSigner(TEST_COMPRESSOR_CONTRACT_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
    });
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_COMPRESSOR_CONTRACT_ADDRESS],
    });
  });

  describe("markBytecodeAsPublished", function () {
    it("non-compressor failed to call", async () => {
      await expect(knownCodesStorage.markBytecodeAsPublished(BYTECODE_HASH_1)).to.be.revertedWith(
        "Callable only by the compressor"
      );
    });

    it("incorrectly formatted bytecode hash failed to call", async () => {
      await expect(
        knownCodesStorage.connect(compressorAccount).markBytecodeAsPublished(INCORRECTLY_FORMATTED_HASH)
      ).to.be.revertedWith("Incorrectly formatted bytecodeHash");
    });

    it("invalid length bytecode hash failed to call", async () => {
      await expect(
        knownCodesStorage.connect(compressorAccount).markBytecodeAsPublished(INVALID_LENGTH_HASH)
      ).to.be.revertedWith("Code length in words must be odd");
    });

    it("successfully marked", async () => {
      await expect(knownCodesStorage.connect(compressorAccount).markBytecodeAsPublished(BYTECODE_HASH_1))
        .to.emit(knownCodesStorage, "MarkedAsKnown")
        .withArgs(BYTECODE_HASH_1.toLowerCase(), false)
        .not.emit(getMock("L1Messenger"), "Called");
      expect(await knownCodesStorage.getMarker(BYTECODE_HASH_1)).to.be.eq(1);
    });

    it("not marked second time", async () => {
      await expect(knownCodesStorage.connect(compressorAccount).markBytecodeAsPublished(BYTECODE_HASH_1)).to.not.emit(
        knownCodesStorage,
        "MarkedAsKnown"
      );
    });
  });

  describe("markFactoryDeps", function () {
    it("non-bootloader failed to call", async () => {
      await expect(knownCodesStorage.markFactoryDeps(false, [BYTECODE_HASH_2, BYTECODE_HASH_3])).to.be.revertedWith(
        "Callable only by the bootloader"
      );
    });

    it("incorrectly formatted bytecode hash failed to call", async () => {
      await expect(
        knownCodesStorage
          .connect(bootloaderAccount)
          .markFactoryDeps(true, [BYTECODE_HASH_2, INCORRECTLY_FORMATTED_HASH])
      ).to.be.revertedWith("Incorrectly formatted bytecodeHash");
    });

    it("invalid length bytecode hash failed to call", async () => {
      await expect(
        knownCodesStorage.connect(bootloaderAccount).markFactoryDeps(false, [INVALID_LENGTH_HASH, BYTECODE_HASH_3])
      ).to.be.revertedWith("Code length in words must be odd");
    });

    it("successfully marked", async () => {
      await expect(
        knownCodesStorage.connect(bootloaderAccount).markFactoryDeps(false, [BYTECODE_HASH_2, BYTECODE_HASH_3])
      )
        .to.emit(knownCodesStorage, "MarkedAsKnown")
        .withArgs(BYTECODE_HASH_2.toLowerCase(), false)
        .emit(knownCodesStorage, "MarkedAsKnown")
        .withArgs(BYTECODE_HASH_3.toLowerCase(), false)
        .not.emit(getMock("L1Messenger"), "Called");
      expect(await knownCodesStorage.getMarker(BYTECODE_HASH_2)).to.be.eq(1);
      expect(await knownCodesStorage.getMarker(BYTECODE_HASH_3)).to.be.eq(1);
    });

    it("not marked second time", async () => {
      await expect(
        knownCodesStorage.connect(bootloaderAccount).markFactoryDeps(false, [BYTECODE_HASH_2, BYTECODE_HASH_3])
      ).to.not.emit(knownCodesStorage, "MarkedAsKnown");
    });

    it("sent to l1", async () => {
      await expect(knownCodesStorage.connect(bootloaderAccount).markFactoryDeps(true, [BYTECODE_HASH_4]))
        .to.emit(knownCodesStorage, "MarkedAsKnown")
        .withArgs(BYTECODE_HASH_4.toLowerCase(), true)
        .emit(getMock("L1Messenger"), "Called")
        .withArgs(0, await encodeCalldata("L1Messenger", "requestBytecodeL1Publication", [BYTECODE_HASH_4]));
      expect(await knownCodesStorage.getMarker(BYTECODE_HASH_4)).to.be.eq(1);
    });
  });

  describe("getMarker", function () {
    it("not known", async () => {
      expect(await knownCodesStorage.getMarker(INCORRECTLY_FORMATTED_HASH)).to.be.eq(0);
    });

    it("known", async () => {
      expect(await knownCodesStorage.getMarker(BYTECODE_HASH_1)).to.be.eq(1);
    });
  });
});

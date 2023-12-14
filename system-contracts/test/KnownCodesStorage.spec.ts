import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-web3";
import type { KnownCodesStorage, MockL1Messenger } from "../typechain";
import { MockL1MessengerFactory } from "../typechain";
import {
  BOOTLOADER_FORMAL_ADDRESS,
  COMPRESSOR_CONTRACT_ADDRESS,
  L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS,
} from "./shared/constants";
import { deployContract, getCode, getWallets, loadArtifact, setCode } from "./shared/utils";

describe("KnownCodesStorage tests", function () {
  let wallet: Wallet;
  let knownCodesStorage: KnownCodesStorage;
  let mockL1Messenger: MockL1Messenger;
  let bootloaderAccount: ethers.Signer;
  let compressorAccount: ethers.Signer;

  let _l1MessengerCode: string;

  const BYTECODE_HASH_1 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";
  const BYTECODE_HASH_2 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEE1";
  const BYTECODE_HASH_3 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEE2";
  const BYTECODE_HASH_4 = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEE3";
  const INCORRECTLY_FORMATTED_HASH = "0x0120FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";
  const INVALID_LENGTH_HASH = "0x0100FFFEDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";

  before(async () => {
    wallet = (await getWallets())[0];
    knownCodesStorage = (await deployContract("KnownCodesStorage")) as KnownCodesStorage;

    _l1MessengerCode = await getCode(L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS);
    const l1MessengerArtifact = await loadArtifact("MockL1Messenger");
    await setCode(L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, l1MessengerArtifact.bytecode);
    mockL1Messenger = MockL1MessengerFactory.connect(L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, wallet);

    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [BOOTLOADER_FORMAL_ADDRESS],
    });
    await network.provider.request({
      method: "hardhat_impersonateAccount",
      params: [COMPRESSOR_CONTRACT_ADDRESS],
    });
    bootloaderAccount = await ethers.getSigner(BOOTLOADER_FORMAL_ADDRESS);
    compressorAccount = await ethers.getSigner(COMPRESSOR_CONTRACT_ADDRESS);
  });

  after(async () => {
    await setCode(L1_MESSENGER_SYSTEM_CONTRACT_ADDRESS, _l1MessengerCode);
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [BOOTLOADER_FORMAL_ADDRESS],
    });
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [COMPRESSOR_CONTRACT_ADDRESS],
    });
  });

  describe("markBytecodeAsPublished", function () {
    it("non-compressor failed to call", async () => {
      await expect(knownCodesStorage.markBytecodeAsPublished(BYTECODE_HASH_1)).to.be.revertedWith(
        "Callable only by the compressor"
      );
    });

    it("incorrectly fomatted bytecode hash failed to call", async () => {
      await expect(
        knownCodesStorage.connect(compressorAccount).markBytecodeAsPublished(INCORRECTLY_FORMATTED_HASH)
      ).to.be.revertedWith("Incorrectly formatted bytecodeHash");
    });

    it("invalid length bytecode hash failed to call", async () => {
      await expect(
        knownCodesStorage.connect(compressorAccount).markBytecodeAsPublished(INVALID_LENGTH_HASH)
      ).to.be.revertedWith("Code length in words must be odd");
    });

    it("successfuly marked", async () => {
      await expect(knownCodesStorage.connect(compressorAccount).markBytecodeAsPublished(BYTECODE_HASH_1))
        .to.emit(knownCodesStorage, "MarkedAsKnown")
        .withArgs(BYTECODE_HASH_1.toLowerCase(), false)
        .not.emit(mockL1Messenger, "MockBytecodeL1Published");
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

    it("incorrectly fomatted bytecode hash failed to call", async () => {
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

    it("successfuly marked", async () => {
      await expect(
        knownCodesStorage.connect(bootloaderAccount).markFactoryDeps(false, [BYTECODE_HASH_2, BYTECODE_HASH_3])
      )
        .to.emit(knownCodesStorage, "MarkedAsKnown")
        .withArgs(BYTECODE_HASH_2.toLowerCase(), false)
        .emit(knownCodesStorage, "MarkedAsKnown")
        .withArgs(BYTECODE_HASH_3.toLowerCase(), false)
        .not.emit(mockL1Messenger, "MockBytecodeL1Published");
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
        .emit(mockL1Messenger, "MockBytecodeL1Published")
        .withArgs(BYTECODE_HASH_4.toLowerCase());
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

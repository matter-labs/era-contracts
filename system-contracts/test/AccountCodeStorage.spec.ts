import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { Wallet } from "zksync-ethers";
import type { AccountCodeStorage } from "../typechain";
import { AccountCodeStorageFactory } from "../typechain";
import {
  EMPTY_STRING_KECCAK,
  ONE_BYTES32_HEX,
  TEST_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS,
  TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
} from "./shared/constants";
import { prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";

describe("AccountCodeStorage tests", function () {
  let wallet: Wallet;
  let deployerAccount: ethers.Signer;

  let accountCodeStorage: AccountCodeStorage;

  const CONSTRUCTING_BYTECODE_HASH = "0x0101FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";
  const CONSTRUCTED_BYTECODE_HASH = "0x0100FFFFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEFDEADBEEF";
  const RANDOM_ADDRESS = "0xdeadbeefdeadbeefdeadbeefdeadbeefdeadbeef";

  before(async () => {
    await prepareEnvironment();

    wallet = getWallets()[0];

    await deployContractOnAddress(TEST_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS, "AccountCodeStorage");
    accountCodeStorage = AccountCodeStorageFactory.connect(TEST_ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT_ADDRESS, wallet);

    deployerAccount = await ethers.getImpersonatedSigner(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS],
    });
  });

  describe("storeAccountConstructingCodeHash", function () {
    it("non-deployer failed to call", async () => {
      await expect(
        accountCodeStorage.storeAccountConstructingCodeHash(RANDOM_ADDRESS, CONSTRUCTING_BYTECODE_HASH)
      ).to.be.revertedWith("Callable only by the deployer system contract");
    });

    it("failed to set with constructed bytecode", async () => {
      await expect(
        accountCodeStorage
          .connect(deployerAccount)
          .storeAccountConstructingCodeHash(RANDOM_ADDRESS, CONSTRUCTED_BYTECODE_HASH)
      ).to.be.revertedWith("Code hash is not for a contract on constructor");
    });

    it("successfully stored", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructingCodeHash(RANDOM_ADDRESS, CONSTRUCTING_BYTECODE_HASH);

      expect(await accountCodeStorage.getRawCodeHash(RANDOM_ADDRESS)).to.be.eq(
        CONSTRUCTING_BYTECODE_HASH.toLowerCase()
      );

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });
  });

  describe("storeAccountConstructedCodeHash", function () {
    it("non-deployer failed to call", async () => {
      await expect(
        accountCodeStorage.storeAccountConstructedCodeHash(RANDOM_ADDRESS, CONSTRUCTING_BYTECODE_HASH)
      ).to.be.revertedWith("Callable only by the deployer system contract");
    });

    it("failed to set with constructing bytecode", async () => {
      await expect(
        accountCodeStorage
          .connect(deployerAccount)
          .storeAccountConstructedCodeHash(RANDOM_ADDRESS, CONSTRUCTING_BYTECODE_HASH)
      ).to.be.revertedWith("Code hash is not for a constructed contract");
    });

    it("successfully stored", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructedCodeHash(RANDOM_ADDRESS, CONSTRUCTED_BYTECODE_HASH);

      expect(await accountCodeStorage.getRawCodeHash(RANDOM_ADDRESS)).to.be.eq(CONSTRUCTED_BYTECODE_HASH.toLowerCase());

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });
  });

  describe("markAccountCodeHashAsConstructed", function () {
    it("non-deployer failed to call", async () => {
      await expect(accountCodeStorage.markAccountCodeHashAsConstructed(RANDOM_ADDRESS)).to.be.revertedWith(
        "Callable only by the deployer system contract"
      );
    });

    it("failed to mark already constructed bytecode", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructedCodeHash(RANDOM_ADDRESS, CONSTRUCTED_BYTECODE_HASH);

      await expect(
        accountCodeStorage.connect(deployerAccount).markAccountCodeHashAsConstructed(RANDOM_ADDRESS)
      ).to.be.revertedWith("Code hash is not for a contract on constructor");

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });

    it("successfully marked", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructingCodeHash(RANDOM_ADDRESS, CONSTRUCTING_BYTECODE_HASH);

      await accountCodeStorage.connect(deployerAccount).markAccountCodeHashAsConstructed(RANDOM_ADDRESS);

      expect(await accountCodeStorage.getRawCodeHash(RANDOM_ADDRESS)).to.be.eq(CONSTRUCTED_BYTECODE_HASH.toLowerCase());

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });
  });

  describe("getRawCodeHash", function () {
    it("zero", async () => {
      expect(await accountCodeStorage.getRawCodeHash(RANDOM_ADDRESS)).to.be.eq(ethers.constants.HashZero);
    });

    it("non-zero", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructedCodeHash(RANDOM_ADDRESS, CONSTRUCTED_BYTECODE_HASH);

      expect(await accountCodeStorage.getRawCodeHash(RANDOM_ADDRESS)).to.be.eq(CONSTRUCTED_BYTECODE_HASH.toLowerCase());

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });
  });

  describe("getCodeHash", function () {
    it("precompile min address", async () => {
      // Check that the smallest precompile has EMPTY_STRING_KECCAK hash
      expect(await accountCodeStorage.getCodeHash("0x0000000000000000000000000000000000000001")).to.be.eq(
        EMPTY_STRING_KECCAK
      );
    });

    it("precompile max address", async () => {
      // Check that the upper end of the precompile range has EMPTY_STRING_KECCAK hash
      expect(await accountCodeStorage.getCodeHash("0x00000000000000000000000000000000000000ff")).to.be.eq(
        EMPTY_STRING_KECCAK
      );
    });

    it("EOA with non-zero nonce", async () => {
      await setResult("NonceHolder", "getRawNonce", [RANDOM_ADDRESS], {
        failure: false,
        returnData: ONE_BYTES32_HEX,
      });
      expect(await accountCodeStorage.getCodeHash(RANDOM_ADDRESS)).to.be.eq(EMPTY_STRING_KECCAK);
    });

    it("address in the constructor", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructingCodeHash(RANDOM_ADDRESS, CONSTRUCTING_BYTECODE_HASH);

      expect(await accountCodeStorage.getCodeHash(RANDOM_ADDRESS)).to.be.eq(EMPTY_STRING_KECCAK);

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });

    it("constructed code hash", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructedCodeHash(RANDOM_ADDRESS, CONSTRUCTED_BYTECODE_HASH);

      expect(await accountCodeStorage.getCodeHash(RANDOM_ADDRESS)).to.be.eq(CONSTRUCTED_BYTECODE_HASH.toLowerCase());

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });

    it("zero", async () => {
      await setResult("NonceHolder", "getRawNonce", [RANDOM_ADDRESS], {
        failure: false,
        returnData: ethers.constants.HashZero,
      });
      expect(await accountCodeStorage.getCodeHash(RANDOM_ADDRESS)).to.be.eq(ethers.constants.HashZero);
    });
  });

  describe("getCodeSize", function () {
    it("zero address", async () => {
      expect(await accountCodeStorage.getCodeSize(ethers.constants.AddressZero)).to.be.eq(0);
    });

    it("precompile", async () => {
      expect(await accountCodeStorage.getCodeSize("0x0000000000000000000000000000000000000001")).to.be.eq(0);
    });

    it("address in the constructor", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructingCodeHash(RANDOM_ADDRESS, CONSTRUCTING_BYTECODE_HASH);

      expect(await accountCodeStorage.getCodeSize(RANDOM_ADDRESS)).to.be.eq(0);

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });

    it("non-zero size", async () => {
      await accountCodeStorage
        .connect(deployerAccount)
        .storeAccountConstructedCodeHash(RANDOM_ADDRESS, CONSTRUCTED_BYTECODE_HASH);

      expect(await accountCodeStorage.getCodeSize(RANDOM_ADDRESS)).to.be.eq(65535 * 32);

      await unsetCodeHash(accountCodeStorage, RANDOM_ADDRESS);
    });

    it("zero", async () => {
      expect(await accountCodeStorage.getCodeSize(RANDOM_ADDRESS)).to.be.eq(0);
    });
  });
});

// Utility function to unset code hash for the specified address.
// Deployer system contract should be impersonated
async function unsetCodeHash(accountCodeStorage: AccountCodeStorage, address: string) {
  const deployerAccount = await ethers.getImpersonatedSigner(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);

  await accountCodeStorage.connect(deployerAccount).storeAccountConstructedCodeHash(address, ethers.constants.HashZero);
}

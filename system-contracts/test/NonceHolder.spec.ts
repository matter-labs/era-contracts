import { expect } from "chai";
import type { NonceHolder } from "../typechain";
import { NonceHolderFactory } from "../typechain";
import {
  TEST_BOOTLOADER_FORMAL_ADDRESS,
  TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
  TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS,
} from "./shared/constants";
import { prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";
import { ethers, network } from "hardhat";

describe("NonceHolder tests", () => {
  const wallet = getWallets()[0];
  let nonceHolder: NonceHolder;
  let nonceHolderAccount: ethers.Signer;
  let deployerAccount: ethers.Signer;

  before(async () => {
    await prepareEnvironment();
    deployContractOnAddress(TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, "NonceHolder");
    nonceHolder = NonceHolderFactory.connect(TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, wallet);
    nonceHolderAccount = await ethers.getImpersonatedSigner(TEST_BOOTLOADER_FORMAL_ADDRESS);
    deployerAccount = await ethers.getImpersonatedSigner(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS],
    });

    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_BOOTLOADER_FORMAL_ADDRESS],
    });
  });

  describe("increaseMinNonce", () => {
    it("should revert This method require system call flag", async () => {
      await expect(nonceHolder.increaseMinNonce(5))
        .to.be.rejectedWith("This method require system call flag")
        .to.be.rejectedWith("This method require system call flag");
    });

    it("should increase account minNonce", async () => {
      await nonceHolder.connect(deployerAccount).increaseMinNonce(123);
      await nonceHolder.connect(deployerAccount).increaseMinNonce(123);
    });
  });

  describe("getMinNonce", async () => {
    it("should get account nonce", async () => {
      const result = await nonceHolder.getMinNonce(deployerAccount.address);
      expect(result).to.equal(123);
    });
  });

  describe("getRawNonce", async () => {
    it("should get account raw nonce", async () => {
      const result = await nonceHolder.getRawNonce(deployerAccount.address);
      expect(result).to.equal(123);
    });
  });

  describe("incrementMinNonceIfEquals", async () => {
    it("should revert This method require system call flag", async () => {
      const expectedNonce = await nonceHolder.getMinNonce(deployerAccount.address);
      await expect(nonceHolder.incrementMinNonceIfEquals(expectedNonce)).to.be.rejectedWith(
        "This method require system call flag"
      );
    });

    it("should revert Incorrect nonce", async () => {
      const expectedNonce = 2222222;
      await expect(nonceHolder.connect(deployerAccount).incrementMinNonceIfEquals(expectedNonce)).to.be.rejectedWith(
        "Incorrect nonce"
      );
    });

    it("should increment minNonce if equals to expected", async () => {
      const expectedNonce = await nonceHolder.getMinNonce(deployerAccount.address);
      await nonceHolder.connect(deployerAccount).incrementMinNonceIfEquals(expectedNonce);
    });
  });

  describe("incrementDeploymentNonce", async () => {
    it("should revert Only the contract deployer can increment the deployment nonce", async () => {
      await expect(nonceHolder.incrementDeploymentNonce(nonceHolderAccount.address)).to.be.rejectedWith(
        "Only the contract deployer can increment the deployment nonce"
      );
    });

    it("should increment deployment nonce", async () => {
      await nonceHolder.connect(deployerAccount).incrementDeploymentNonce(nonceHolderAccount.address);
    });
  });

  describe("getDeploymentNonce", async () => {
    it("should get deployment nonce", async () => {
      const result = await nonceHolder.getDeploymentNonce(nonceHolderAccount.address);
      expect(result).to.equal(1);
    });
  });

  describe("setValueUnderNonce", async () => {
    it("should revert Nonce value cannot be set to 0", async () => {
      const accountInfo = [1, 0];

      const encodedAccountInfo = ethers.utils.defaultAbiCoder.encode(["tuple(uint8, uint8)"], [accountInfo]);

      await setResult("ContractDeployer", "getAccountInfo", [nonceHolderAccount.address], {
        failure: false,
        returnData: encodedAccountInfo,
      });
      await expect(nonceHolder.connect(nonceHolderAccount).setValueUnderNonce(124, 0)).to.be.rejectedWith(
        "Nonce value cannot be set to 0"
      );
    });

    it("should revert Previous nonce has not been used", async () => {
      const accountInfo = [1, 0];

      const encodedAccountInfo = ethers.utils.defaultAbiCoder.encode(["tuple(uint8, uint8)"], [accountInfo]);

      await setResult("ContractDeployer", "getAccountInfo", [nonceHolderAccount.address], {
        failure: false,
        returnData: encodedAccountInfo,
      });
      await expect(nonceHolder.connect(nonceHolderAccount).setValueUnderNonce(123, 111)).to.be.rejectedWith(
        "Previous nonce has not been used"
      );
    });

    it("should emit ValueSetUnderNonce event", async () => {
      const expectedNonce = await nonceHolder.getMinNonce(nonceHolderAccount.address);
      await nonceHolder.connect(nonceHolderAccount).incrementMinNonceIfEquals(expectedNonce);
      const accountInfo = [1, 0];

      const encodedAccountInfo = ethers.utils.defaultAbiCoder.encode(["tuple(uint8, uint8)"], [accountInfo]);

      await setResult("ContractDeployer", "getAccountInfo", [nonceHolderAccount.address], {
        failure: false,
        returnData: encodedAccountInfo,
      });
      await expect(nonceHolder.connect(nonceHolderAccount).setValueUnderNonce(expectedNonce.add(1), 333))
        .to.emit(nonceHolder, "ValueSetUnderNonce")
        .withArgs(nonceHolderAccount.address, expectedNonce.add(1), 333);
    });
  });

  describe("getValueUnderNonce", () => {
    it("should get value under nonce", async () => {
      const key = await nonceHolder.getMinNonce(nonceHolderAccount.address);
      const storedValue = await nonceHolder.connect(nonceHolderAccount).getValueUnderNonce(key);
      expect(storedValue).to.equal(333);
    });
  });

  describe("isNonceUsed", () => {
    it("used nonce", async () => {
      const isUsed = await nonceHolder.isNonceUsed(nonceHolderAccount.address, 1);
      expect(isUsed).to.equal(true);
    });

    it("not used nonce", async () => {
      const isUsed = await nonceHolder.isNonceUsed(nonceHolderAccount.address, 2222222);
      expect(isUsed).to.equal(false);
    });
  });

  describe("validateNonceUsage", () => {
    it("used nonce & should not be used", async () => {
      await expect(nonceHolder.validateNonceUsage(nonceHolderAccount.address, 1, false)).to.be.rejectedWith(
        "Reusing the same nonce twice"
      );
    });

    it("used nonce & should be used", async () => {
      await nonceHolder.validateNonceUsage(nonceHolderAccount.address, 1, true);
    });

    it("not used nonce & should be used", async () => {
      await expect(nonceHolder.validateNonceUsage(nonceHolderAccount.address, 222, true)).to.be.rejectedWith(
        "The nonce was not set as used"
      );
    });

    it("not used nonce & should not be used", async () => {
      await nonceHolder.validateNonceUsage(nonceHolderAccount.address, 222, false);
    });
  });
});

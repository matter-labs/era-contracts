import { expect } from "chai";
import type { NonceHolder } from "../typechain";
import { NonceHolderFactory } from "../typechain";
import {
  TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS,
  TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS,
  TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS,
} from "./shared/constants";
import { prepareEnvironment, setResult } from "./shared/mocks";
import { deployContractOnAddress, getWallets } from "./shared/utils";
import { ethers, network } from "hardhat";
import { BigNumber } from "ethers";

describe("NonceHolder tests", () => {
  const wallet = getWallets()[0];
  let nonceHolder: NonceHolder;
  let systemAccount: ethers.Signer;
  let deployerAccount: ethers.Signer;

  before(async () => {
    await prepareEnvironment();
    await deployContractOnAddress(TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, "NonceHolder");
    nonceHolder = NonceHolderFactory.connect(TEST_NONCE_HOLDER_SYSTEM_CONTRACT_ADDRESS, wallet);

    // Using a system account to satisfy the `onlySystemCall` modifier.
    systemAccount = await ethers.getImpersonatedSigner(TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS);
    deployerAccount = await ethers.getImpersonatedSigner(TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS);
  });

  after(async () => {
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_SYSTEM_CONTEXT_CONTRACT_ADDRESS],
    });
    await network.provider.request({
      method: "hardhat_stopImpersonatingAccount",
      params: [TEST_DEPLOYER_SYSTEM_CONTRACT_ADDRESS],
    });
  });

  describe("increaseMinNonce and getters", () => {
    it("should increase account minNonce by 1", async () => {
      const nonceBefore = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceBefore = await nonceHolder.getRawNonce(systemAccount.address);
      await nonceHolder.connect(systemAccount).increaseMinNonce(1);
      const nonceAfter = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceAfter = await nonceHolder.getRawNonce(systemAccount.address);

      expect(nonceAfter).to.equal(nonceBefore.add(1));
      expect(rawNonceAfter).to.equal(rawNonceBefore.add(1));
    });

    it("should stay the same", async () => {
      const nonceBefore = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceBefore = await nonceHolder.getRawNonce(systemAccount.address);
      await nonceHolder.connect(systemAccount).increaseMinNonce(0);
      const nonceAfter = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceAfter = await nonceHolder.getRawNonce(systemAccount.address);

      expect(nonceBefore).to.equal(nonceAfter);
      expect(rawNonceBefore).to.equal(rawNonceAfter);
    });

    it("should increase account minNonce by many", async () => {
      const nonceBefore = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceBefore = await nonceHolder.getRawNonce(systemAccount.address);
      await nonceHolder.connect(systemAccount).increaseMinNonce(2 ** 4);
      const nonceAfter = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceAfter = await nonceHolder.getRawNonce(systemAccount.address);

      expect(nonceAfter).to.equal(nonceBefore.add(2 ** 4));
      expect(rawNonceAfter).to.equal(rawNonceBefore.add(2 ** 4));
    });

    it("should fail with too high", async () => {
      const nonceBefore = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceBefore = await nonceHolder.getRawNonce(systemAccount.address);

      await expect(
        nonceHolder.connect(systemAccount).increaseMinNonce(BigNumber.from(2).pow(32).add(1))
      ).to.be.revertedWithCustomError(nonceHolder, "NonceIncreaseError");

      const nonceAfter = await nonceHolder.getMinNonce(systemAccount.address);
      const rawNonceAfter = await nonceHolder.getRawNonce(systemAccount.address);

      expect(nonceAfter).to.equal(nonceBefore);
      expect(rawNonceAfter).to.equal(rawNonceBefore);
    });

    it("should revert This method require system call flag", async () => {
      await expect(nonceHolder.increaseMinNonce(123)).to.be.revertedWithCustomError(
        nonceHolder,
        "SystemCallFlagRequired"
      );
    });
  });

  describe("incrementMinNonceIfEquals", async () => {
    it("should revert This method require system call flag", async () => {
      const expectedNonce = await nonceHolder.getMinNonce(systemAccount.address);
      await expect(nonceHolder.incrementMinNonceIfEquals(expectedNonce)).to.be.revertedWithCustomError(
        nonceHolder,
        "SystemCallFlagRequired"
      );
    });

    it("should revert Incorrect nonce", async () => {
      await expect(nonceHolder.connect(systemAccount).incrementMinNonceIfEquals(2222222)).to.be.revertedWithCustomError(
        nonceHolder,
        "ValuesNotEqual"
      );
    });

    it("should increment minNonce if equals to expected", async () => {
      const expectedNonce = await nonceHolder.getMinNonce(systemAccount.address);
      await nonceHolder.connect(systemAccount).incrementMinNonceIfEquals(expectedNonce);
      const result = await nonceHolder.getMinNonce(systemAccount.address);
      expect(result).to.equal(expectedNonce.add(1));
    });
  });

  describe("incrementDeploymentNonce", async () => {
    it("should revert Only the contract deployer can increment the deployment nonce", async () => {
      await expect(nonceHolder.incrementDeploymentNonce(deployerAccount.address)).to.be.revertedWithCustomError(
        nonceHolder,
        "Unauthorized"
      );
    });

    it("should increment deployment nonce", async () => {
      const nonceBefore = await nonceHolder.getDeploymentNonce(wallet.address);
      const rawNonceBefore = await nonceHolder.getRawNonce(wallet.address);
      await nonceHolder.connect(deployerAccount).incrementDeploymentNonce(wallet.address);
      const nonceAfter = await nonceHolder.getDeploymentNonce(wallet.address);
      const rawNonceAfter = await nonceHolder.getRawNonce(wallet.address);

      expect(nonceAfter).to.equal(nonceBefore.add(BigNumber.from(1)));
      expect(rawNonceAfter).to.equal(rawNonceBefore.add(BigNumber.from(2).pow(128)));
    });
  });

  describe("setValueUnderNonce and getValueUnderNonce", async () => {
    it("should revert Nonce value cannot be set to 0", async () => {
      const accountInfo = [1, 0];
      const encodedAccountInfo = ethers.utils.defaultAbiCoder.encode(["tuple(uint8, uint8)"], [accountInfo]);
      await setResult("ContractDeployer", "getAccountInfo", [systemAccount.address], {
        failure: false,
        returnData: encodedAccountInfo,
      });
      await expect(nonceHolder.connect(systemAccount).setValueUnderNonce(124, 0)).to.be.revertedWithCustomError(
        nonceHolder,
        "ZeroNonceError"
      );
    });

    it("should revert Previous nonce has not been used", async () => {
      const accountInfo = [1, 0];
      const encodedAccountInfo = ethers.utils.defaultAbiCoder.encode(["tuple(uint8, uint8)"], [accountInfo]);
      await setResult("ContractDeployer", "getAccountInfo", [systemAccount.address], {
        failure: false,
        returnData: encodedAccountInfo,
      });
      await expect(nonceHolder.connect(systemAccount).setValueUnderNonce(443, 111)).to.be.revertedWithCustomError(
        nonceHolder,
        "NonceJumpError"
      );
    });

    it("should emit ValueSetUnderNonce event", async () => {
      const currentNonce = await nonceHolder.getMinNonce(systemAccount.address);
      const valueBefore = await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce);
      const value = valueBefore.add(42);

      const accountInfo = [1, 0];
      const encodedAccountInfo = ethers.utils.defaultAbiCoder.encode(["tuple(uint8, uint8)"], [accountInfo]);
      await setResult("ContractDeployer", "getAccountInfo", [systemAccount.address], {
        failure: false,
        returnData: encodedAccountInfo,
      });
      await expect(nonceHolder.connect(systemAccount).setValueUnderNonce(currentNonce, value))
        .to.emit(nonceHolder, "ValueSetUnderNonce")
        .withArgs(systemAccount.address, currentNonce, value);

      const valueAfter = await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce);
      expect(valueAfter).to.equal(value);
    });

    it("should emit ValueSetUnderNonce event arbitrary ordering", async () => {
      const currentNonce = await nonceHolder.getMinNonce(systemAccount.address);
      const encodedAccountInfo = ethers.utils.defaultAbiCoder.encode(["tuple(uint8, uint8)"], [[1, 1]]);
      await setResult("ContractDeployer", "getAccountInfo", [systemAccount.address], {
        failure: false,
        returnData: encodedAccountInfo,
      });

      const firstValue = (await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce)).add(111);
      await expect(nonceHolder.connect(systemAccount).setValueUnderNonce(currentNonce, firstValue))
        .to.emit(nonceHolder, "ValueSetUnderNonce")
        .withArgs(systemAccount.address, currentNonce, firstValue);

      const secondValue = (await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce.add(2))).add(333);
      await expect(nonceHolder.connect(systemAccount).setValueUnderNonce(currentNonce.add(2), secondValue))
        .to.emit(nonceHolder, "ValueSetUnderNonce")
        .withArgs(systemAccount.address, currentNonce.add(2), secondValue);

      const thirdValue = (await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce.add(1))).add(222);
      await expect(nonceHolder.connect(systemAccount).setValueUnderNonce(currentNonce.add(1), thirdValue))
        .to.emit(nonceHolder, "ValueSetUnderNonce")
        .withArgs(systemAccount.address, currentNonce.add(1), thirdValue);

      const storedValue = await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce);
      expect(storedValue).to.equal(firstValue);
      const storedValueNext = await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce.add(1));
      expect(storedValueNext).to.equal(thirdValue);
      const storedAfterNext = await nonceHolder.connect(systemAccount).getValueUnderNonce(currentNonce.add(2));
      expect(storedAfterNext).to.equal(secondValue);
    });
  });

  describe("isNonceUsed", () => {
    it("used nonce because it too small", async () => {
      const isUsed = await nonceHolder.isNonceUsed(systemAccount.address, 1);
      expect(isUsed).to.equal(true);
    });

    it("used nonce because set", async () => {
      const currentNonce = await nonceHolder.getMinNonce(systemAccount.address);
      const checkedNonce = currentNonce.add(1);
      await nonceHolder.connect(systemAccount).setValueUnderNonce(checkedNonce, 5);

      const isUsed = await nonceHolder.isNonceUsed(systemAccount.address, checkedNonce);
      expect(isUsed).to.equal(true);
    });

    it("not used nonce", async () => {
      const currentNonce = await nonceHolder.getMinNonce(systemAccount.address);
      const checkedNonce = currentNonce.add(2137 * 2 ** 10);

      const isUsed = await nonceHolder.isNonceUsed(systemAccount.address, checkedNonce);
      expect(isUsed).to.be.false;
    });
  });

  describe("validateNonceUsage", () => {
    it("used nonce & should not be used", async () => {
      await expect(nonceHolder.validateNonceUsage(systemAccount.address, 1, false)).to.be.revertedWithCustomError(
        nonceHolder,
        "NonceAlreadyUsed"
      );
    });

    it("used nonce & should be used", async () => {
      await nonceHolder.validateNonceUsage(systemAccount.address, 1, true);
    });

    it("not used nonce & should be used", async () => {
      await expect(nonceHolder.validateNonceUsage(systemAccount.address, 2 ** 16, true)).to.be.revertedWithCustomError(
        nonceHolder,
        "NonceNotUsed"
      );
    });

    it("not used nonce & should not be used", async () => {
      await nonceHolder.validateNonceUsage(systemAccount.address, 2 ** 16, false);
    });
  });
});

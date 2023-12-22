import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { ComplexUpgrader, MockContract } from "../typechain";
import { ComplexUpgraderFactory } from "../typechain";
import { TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS, TEST_FORCE_DEPLOYER_ADDRESS } from "./shared/constants";
import { deployContract, deployContractOnAddress, getWallets } from "./shared/utils";

describe("ComplexUpgrader tests", function () {
  let complexUpgrader: ComplexUpgrader;
  let dummyUpgrade: MockContract;

  before(async () => {
    const wallet = (await getWallets())[0];
    await deployContractOnAddress(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS, "ComplexUpgrader");
    complexUpgrader = ComplexUpgraderFactory.connect(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS, wallet);
    dummyUpgrade = (await deployContract("MockContract")) as MockContract;
  });

  describe("upgrade", function () {
    it("non force deployer failed to call", async () => {
      await expect(complexUpgrader.upgrade(dummyUpgrade.address, "0xdeadbeef")).to.be.revertedWith(
        "Can only be called by FORCE_DEPLOYER"
      );
    });

    it("successfully upgraded", async () => {
      const force_deployer = await ethers.getImpersonatedSigner(TEST_FORCE_DEPLOYER_ADDRESS);

      await expect(complexUpgrader.connect(force_deployer).upgrade(dummyUpgrade.address, "0xdeadbeef"))
        .to.emit(dummyUpgrade.attach(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS), "Called")
        .withArgs(0, "0xdeadbeef");

      await network.provider.request({
        method: "hardhat_stopImpersonatingAccount",
        params: [TEST_FORCE_DEPLOYER_ADDRESS],
      });
    });
  });
});

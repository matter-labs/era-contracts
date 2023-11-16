import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { ComplexUpgrader, DummyUpgrade } from "../typechain-types";
import { FORCE_DEPLOYER_ADDRESS } from "./shared/constants";
import { deployContract } from "./shared/utils";

describe("ComplexUpgrader tests", function () {
  let complexUpgrader: ComplexUpgrader;
  let dummyUpgrade: DummyUpgrade;

  before(async () => {
    complexUpgrader = (await deployContract("ComplexUpgrader")) as ComplexUpgrader;
    dummyUpgrade = (await deployContract("DummyUpgrade")) as DummyUpgrade;
  });

  describe("upgrade", function () {
    it("non force deployer failed to call", async () => {
      await expect(
        complexUpgrader.upgrade(dummyUpgrade.address, dummyUpgrade.interface.encodeFunctionData("performUpgrade"))
      ).to.be.revertedWith("Can only be called by FORCE_DEPLOYER");
    });

    it("successfully upgraded", async () => {
      await network.provider.request({
        method: "hardhat_impersonateAccount",
        params: [FORCE_DEPLOYER_ADDRESS],
      });

      const force_deployer = await ethers.getSigner(FORCE_DEPLOYER_ADDRESS);

      await expect(
        complexUpgrader
          .connect(force_deployer)
          .upgrade(dummyUpgrade.address, dummyUpgrade.interface.encodeFunctionData("performUpgrade"))
      ).to.emit(dummyUpgrade.attach(complexUpgrader.address), "Upgraded");

      await network.provider.request({
        method: "hardhat_stopImpersonatingAccount",
        params: [FORCE_DEPLOYER_ADDRESS],
      });
    });
  });
});

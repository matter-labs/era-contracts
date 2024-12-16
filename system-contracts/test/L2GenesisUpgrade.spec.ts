import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { L2GenesisUpgrade } from "../typechain";
import { L2GenesisUpgradeFactory } from "../typechain";
import { TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS, TEST_FORCE_DEPLOYER_ADDRESS } from "./shared/constants";
import { deployContractOnAddress, getWallets } from "./shared/utils";

describe("L2GenesisUpgrade tests", function () {
  let l2GenesisUpgrade: L2GenesisUpgrade;
  const chainId = 270;

  before(async () => {
    const wallet = (await getWallets())[0];
    await deployContractOnAddress(TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS, "L2GenesisUpgrade");
    l2GenesisUpgrade = L2GenesisUpgradeFactory.connect(TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS, wallet);
  });

  describe("upgrade", function () {
    it("successfully upgraded", async () => {
      // const force_deployer = await ethers.getImpersonatedSigner(TEST_FORCE_DEPLOYER_ADDRESS);
      const forceDeployments = ethers.utils.defaultAbiCoder.encode(
        ["tuple(bytes32 bytecodeHash, address newAddress, bool callConstructor, uint256 value, bytes input)[]"],
        [
          [
            {
              bytecodeHash: "0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70",
              newAddress: "0x0000000000000000000000000000000000020002",
              callConstructor: true,
              value: 0,
              input: "0x",
            },
          ],
        ]
      );

      await expect(l2GenesisUpgrade.genesisUpgrade(chainId, forceDeployments))
        .to.emit(l2GenesisUpgrade, "UpgradeComplete")
        .withArgs(chainId);

      await network.provider.request({
        method: "hardhat_stopImpersonatingAccount",
        params: [TEST_FORCE_DEPLOYER_ADDRESS],
      });
    });
  });
});

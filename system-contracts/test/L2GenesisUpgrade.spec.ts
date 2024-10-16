import { expect } from "chai";
import { ethers, network } from "hardhat";
import type { ComplexUpgrader, L2GenesisUpgrade } from "../typechain";
import { ComplexUpgraderFactory, L2GenesisUpgradeFactory } from "../typechain";
import {
  TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS,
  TEST_FORCE_DEPLOYER_ADDRESS,
  REAL_L2_ASSET_ROUTER_ADDRESS,
  REAL_L2_MESSAGE_ROOT_ADDRESS,
  TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS,
} from "./shared/constants";
import { deployContractOnAddress } from "./shared/utils";
import { setResult } from "./shared/mocks";

describe("L2GenesisUpgrade tests", function () {
  let l2GenesisUpgrade: L2GenesisUpgrade;
  let complexUpgrader: ComplexUpgrader;
  const chainId = 270;

  const ctmDeployerAddress = ethers.utils.hexlify(ethers.utils.randomBytes(20));
  const bridgehubOwnerAddress = ethers.utils.hexlify(ethers.utils.randomBytes(20));

  const forceDeployments = [
    {
      bytecodeHash: "0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70",
      newAddress: "0x0000000000000000000000000000000000020002",
      callConstructor: true,
      value: 0,
      input: "0x",
    },
  ];

  before(async () => {
    const wallet = await ethers.getImpersonatedSigner(TEST_FORCE_DEPLOYER_ADDRESS);
    await deployContractOnAddress(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS, "ComplexUpgrader");
    await deployContractOnAddress(TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS, "L2GenesisUpgrade");
    complexUpgrader = ComplexUpgraderFactory.connect(TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS, wallet);
    l2GenesisUpgrade = L2GenesisUpgradeFactory.connect(TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS, wallet);

    await setResult(
      "IBridgehub",
      "setAddresses",
      [REAL_L2_ASSET_ROUTER_ADDRESS, ctmDeployerAddress, REAL_L2_MESSAGE_ROOT_ADDRESS],
      {
        failure: false,
        returnData: "0x",
      }
    );
    await setResult("IBridgehub", "owner", [], {
      failure: false,
      returnData: ethers.utils.defaultAbiCoder.encode(["address"], [bridgehubOwnerAddress]),
    });

    await setResult("SystemContext", "setChainId", [chainId], {
      failure: false,
      returnData: "0x",
    });

    await setResult("ContractDeployer", "forceDeployOnAddresses", [forceDeployments], {
      failure: false,
      returnData: "0x",
    });
  });

  describe("upgrade", function () {
    it("successfully upgraded", async () => {
      const forceDeploymentsData = ethers.utils.defaultAbiCoder.encode(
        ["tuple(bytes32 bytecodeHash, address newAddress, bool callConstructor, uint256 value, bytes input)[]"],
        [forceDeployments]
      );

      const data = l2GenesisUpgrade.interface.encodeFunctionData("genesisUpgrade", [
        chainId,
        ctmDeployerAddress,
        forceDeploymentsData,
      ]);

      // Note, that the event is emitted at the complex upgrader, but the event declaration is taken from the l2GenesisUpgrade contract.
      await expect(complexUpgrader.upgrade(l2GenesisUpgrade.address, data))
        .to.emit(
          new ethers.Contract(complexUpgrader.address, l2GenesisUpgrade.interface, complexUpgrader.signer),
          "UpgradeComplete"
        )
        .withArgs(chainId);

      await network.provider.request({
        method: "hardhat_stopImpersonatingAccount",
        params: [TEST_FORCE_DEPLOYER_ADDRESS],
      });
    });
  });
});

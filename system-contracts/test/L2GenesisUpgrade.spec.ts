import { expect } from "chai";
import { ethers, network } from "hardhat";
import * as zksync from "zksync-ethers";
import type { ComplexUpgrader, L2GenesisUpgrade } from "../typechain";
import { ComplexUpgraderFactory, L2GenesisUpgradeFactory } from "../typechain";
import {
  TEST_L2_GENESIS_UPGRADE_CONTRACT_ADDRESS,
  TEST_FORCE_DEPLOYER_ADDRESS,
  REAL_L2_ASSET_ROUTER_ADDRESS,
  REAL_L2_MESSAGE_ROOT_ADDRESS,
  TEST_COMPLEX_UPGRADER_CONTRACT_ADDRESS,
  ADDRESS_ONE,
} from "./shared/constants";
import { deployContractOnAddress, loadArtifact } from "./shared/utils";
import { prepareEnvironment, setResult } from "./shared/mocks";

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

  let fixedForceDeploymentsData: string;

  const additionalForceDeploymentsData = ethers.utils.defaultAbiCoder.encode(
    [
      "tuple(bytes32 baseTokenAssetId, address l2LegacySharedBridge, address predeployedL2WethAddress, address baseTokenL1Address, string baseTokenName, string baseTokenSymbol)",
    ],
    [
      {
        baseTokenAssetId: "0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70",
        l2LegacySharedBridge: ethers.constants.AddressZero,
        predeployedL2WethAddress: ADDRESS_ONE,
        baseTokenL1Address: ADDRESS_ONE,
        baseTokenName: "Ether",
        baseTokenSymbol: "ETH",
      },
    ]
  );

  before(async () => {
    await prepareEnvironment();

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

    const msgRootBytecode = (await loadArtifact("DummyMessageRoot")).bytecode;
    const messageRootBytecodeHash = zksync.utils.hashBytecode(msgRootBytecode);

    const ntvBytecode = (await loadArtifact("DummyL2NativeTokenVault")).bytecode;
    const ntvBytecodeHash = zksync.utils.hashBytecode(ntvBytecode);

    const l2AssetRouterBytecode = (await loadArtifact("DummyL2AssetRouter")).bytecode;
    const l2AssetRouterBytecodeHash = zksync.utils.hashBytecode(l2AssetRouterBytecode);

    const bridgehubBytecode = (await loadArtifact("DummyBridgehub")).bytecode;
    const bridgehubBytecodeHash = zksync.utils.hashBytecode(bridgehubBytecode);

    fixedForceDeploymentsData = ethers.utils.defaultAbiCoder.encode(
      [
        "tuple(uint256 l1ChainId, uint256 eraChainId, address l1AssetRouter, bytes32 l2TokenProxyBytecodeHash, address aliasedL1Governance, uint256 maxNumberOfZKChains, bytes32 bridgehubBytecodeHash, bytes32 l2AssetRouterBytecodeHash, bytes32 l2NtvBytecodeHash, bytes32 messageRootBytecodeHash, address l2SharedBridgeLegacyImpl, address l2BridgedStandardERC20Impl)",
      ],
      [
        {
          l1ChainId: 1,
          eraChainId: 1,
          l1AssetRouter: ADDRESS_ONE,
          l2TokenProxyBytecodeHash: "0x0100056f53fd9e940906d998a80ed53392e5c50a8eb198baf9f78fd84ce7ec70",
          aliasedL1Governance: ADDRESS_ONE,
          maxNumberOfZKChains: 100,
          bridgehubBytecodeHash: bridgehubBytecodeHash,
          l2AssetRouterBytecodeHash: l2AssetRouterBytecodeHash,
          l2NtvBytecodeHash: ntvBytecodeHash,
          messageRootBytecodeHash: messageRootBytecodeHash,
          // For genesis upgrade these values will always be zero
          l2SharedBridgeLegacyImpl: ethers.constants.AddressZero,
          l2BridgedStandardERC20Impl: ethers.constants.AddressZero,
        },
      ]
    );
  });

  describe("upgrade", function () {
    it("successfully upgraded", async () => {
      const data = l2GenesisUpgrade.interface.encodeFunctionData("genesisUpgrade", [
        chainId,
        ctmDeployerAddress,
        fixedForceDeploymentsData,
        additionalForceDeploymentsData,
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

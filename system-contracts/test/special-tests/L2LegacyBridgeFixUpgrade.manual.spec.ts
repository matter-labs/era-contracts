import { expect } from "chai";
import { ethers } from "hardhat";
import type { Contract } from "zksync-ethers";
import type { ComplexUpgrader, L2LegacyBridgeFixUpgrade } from "../../typechain";
import { ComplexUpgraderFactory, L2LegacyBridgeFixUpgradeFactory } from "../../typechain";
import {
  REAL_FORCE_DEPLOYER_ADDRESS,
  REAL_BRIDGEHUB_ADDRESS,
  REAL_L2_ASSET_ROUTER_ADDRESS,
  REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS,
  PROXY_ADMIN_SLOT,
  REAL_COMPLEX_UPGRADER_CONTRACT_ADDRESS,
} from "../shared/constants";
import { deployContract } from "../shared/utils";
import type { Context } from "mocha";
import { hashBytecode } from "zksync-ethers/build/utils";

describe("L2LegacyBridgeFixUpgrade tests", function () {
  let l2LegacyBridgeFixUpgrade: L2LegacyBridgeFixUpgrade;
  let complexUpgrader: ComplexUpgrader;
  let bridgehub: Contract;
  let assetRouter: Contract;
  let l2NativeTokenVault: Contract;
  let oldBridgedEthVersion: number;

  const aliasedGovernanceAddress = ethers.utils.getAddress(ethers.utils.hexlify(ethers.utils.randomBytes(20)));
  const bridgedEthAssetId = ethers.utils.hexlify(ethers.utils.randomBytes(32));

  before(async () => {
    const wallet = await ethers.getImpersonatedSigner(REAL_FORCE_DEPLOYER_ADDRESS);
    //await deployContractOnAddress(REAL_COMPLEX_UPGRADER_CONTRACT_ADDRESS, "ComplexUpgrader");
    complexUpgrader = ComplexUpgraderFactory.connect(REAL_COMPLEX_UPGRADER_CONTRACT_ADDRESS, wallet);
    const l2LegacyBridgeFixUpgradeContract = await deployContract("L2LegacyBridgeFixUpgrade");
    l2LegacyBridgeFixUpgrade = L2LegacyBridgeFixUpgradeFactory.connect(
      l2LegacyBridgeFixUpgradeContract.address,
      wallet
    );

    // Get the Bridged ETH version, defined only if it was deployed
    l2NativeTokenVault = await ethers.getContractAt("IL2NativeTokenVault", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
    const bridgedEthAddress = await l2NativeTokenVault.tokenAddress(bridgedEthAssetId);
    if (bridgedEthAddress === ethers.constants.AddressZero) {
      const storageValue = await ethers.provider.getStorageAt(bridgedEthAddress, ethers.constants.Zero);
      oldBridgedEthVersion = Number(BigInt(storageValue) & BigInt(0xff));
    }
  });

  describe("upgrade", function () {
    it("successfully upgraded", async () => {
      const bridgeFixData = l2LegacyBridgeFixUpgrade.interface.encodeFunctionData("upgrade", [
        aliasedGovernanceAddress,
        bridgedEthAssetId,
      ]);
      const l2LegacyBridgeFixUpgradeFactory = await ethers.getContractFactory("L2LegacyBridgeFixUpgrade");
      await complexUpgrader.forceDeployAndUpgrade(
        [
          {
            bytecodeHash: hashBytecode(l2LegacyBridgeFixUpgradeFactory.bytecode),
            newAddress: l2LegacyBridgeFixUpgrade.address,
            callConstructor: false,
            value: ethers.constants.Zero,
            input: "0x",
          },
        ],
        l2LegacyBridgeFixUpgrade.address,
        bridgeFixData
      );

      // Check ownership transfer
      bridgehub = await ethers.getContractAt("Ownable2Step", REAL_BRIDGEHUB_ADDRESS);
      assetRouter = await ethers.getContractAt("Ownable2Step", REAL_L2_ASSET_ROUTER_ADDRESS);
      l2NativeTokenVault = await ethers.getContractAt("Ownable2Step", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
      expect(await bridgehub.owner()).to.equal(aliasedGovernanceAddress);
      expect(await assetRouter.owner()).to.equal(aliasedGovernanceAddress);
      expect(await l2NativeTokenVault.owner()).to.equal(aliasedGovernanceAddress);
    });

    let doesL2LegacySharedBridgeExist = true;
    it("Ownership of legacy shared bridge and its beacon proxy was migrated, if applicable", async function (this: Context) {
      // Migration is only needed if legacy shared bridge exists, test is complete if not
      assetRouter = await ethers.getContractAt("IL2AssetRouter", REAL_L2_ASSET_ROUTER_ADDRESS);
      const l2LegacySharedBridge = await assetRouter.L2_LEGACY_SHARED_BRIDGE();
      if (l2LegacySharedBridge === ethers.constants.AddressZero) {
        doesL2LegacySharedBridgeExist = false;
        this.skip();
      }

      // Migrates ownership of the legacy shared bridge to the aliased governance address
      const proxyAdminAddress = await ethers.provider.getStorageAt(l2LegacySharedBridge, PROXY_ADMIN_SLOT);
      const proxyAdmin = await ethers.getContractAt("ProxyAdmin", proxyAdminAddress);
      expect(await proxyAdmin.owner()).to.equal(aliasedGovernanceAddress);

      // Migrates ownership of the beacon proxy to the aliased governance address
      const l2TokenBeacon = await ethers.getContractAt("IL2SharedBridgeLegacy", l2LegacySharedBridge);
      expect(await l2TokenBeacon.owner()).to.equal(aliasedGovernanceAddress);
    });

    it("Patches the bridged ETH token metadata bug, if applicable", async function (this: Context) {
      if (!doesL2LegacySharedBridgeExist) this.skip();
      // Reinitialized bridged ETH only if it was deployed
      l2NativeTokenVault = await ethers.getContractAt("IL2NativeTokenVault", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
      const bridgedEthAddress = await l2NativeTokenVault.tokenAddress(bridgedEthAssetId);

      // Version is increased by 1
      const storageValue = await ethers.provider.getStorageAt(bridgedEthAddress, ethers.constants.Zero);
      const newBridgedEthVersion = Number(BigInt(storageValue) & BigInt(0xff));
      expect(newBridgedEthVersion).to.equal(oldBridgedEthVersion + 1);

      // Bridged ETH `name`, `symbol`, and `decimals` getters work correctly
      const bridgedEth = await ethers.getContractAt("IERC20Metadata", bridgedEthAddress);
      expect(await bridgedEth.name()).to.equal("Ether");
      expect(await bridgedEth.symbol()).to.equal("ETH");
      expect(await bridgedEth.decimals()).to.equal(18);
    });

    it("preserves existing ownership when already set to aliased governance", async () => {
      assetRouter = await ethers.getContractAt("Ownable2Step", REAL_L2_ASSET_ROUTER_ADDRESS);

      // Store original owners to verify no changes
      bridgehub = await ethers.getContractAt("Ownable2Step", REAL_BRIDGEHUB_ADDRESS);
      assetRouter = await ethers.getContractAt("Ownable2Step", REAL_L2_ASSET_ROUTER_ADDRESS);
      l2NativeTokenVault = await ethers.getContractAt("Ownable2Step", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
      const originalBridgehubOwner = await bridgehub.owner();
      const originalAssetRouterOwner = await assetRouter.owner();
      const originalL2NativeTokenVaultOwner = await l2NativeTokenVault.owner();

      // Perform upgrade with same aliased governance address
      const data = l2LegacyBridgeFixUpgrade.interface.encodeFunctionData("upgrade", [
        aliasedGovernanceAddress,
        bridgedEthAssetId,
      ]);
      await complexUpgrader.upgrade(l2LegacyBridgeFixUpgrade.address, data);

      // Verify owners remained unchanged
      expect(await bridgehub.owner()).to.equal(originalBridgehubOwner);
      expect(await assetRouter.owner()).to.equal(originalAssetRouterOwner);
      expect(await l2NativeTokenVault.owner()).to.equal(originalL2NativeTokenVaultOwner);
    });
  });
});

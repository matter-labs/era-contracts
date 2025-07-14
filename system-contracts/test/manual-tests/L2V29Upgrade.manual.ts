import { expect } from "chai";
import { ethers } from "hardhat";
import { create2Address, hashBytecode } from "zksync-ethers/build/utils";
import { ComplexUpgraderFactory } from "../../typechain";
import {
  REAL_FORCE_DEPLOYER_ADDRESS,
  REAL_BRIDGEHUB_ADDRESS,
  REAL_L2_ASSET_ROUTER_ADDRESS,
  REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS,
  PROXY_ADMIN_SLOT,
  REAL_COMPLEX_UPGRADER_CONTRACT_ADDRESS,
} from "../shared/constants";
import { publishBytecode } from "../shared/utils";
import type { Context } from "mocha";

describe("L2V29Upgrade fork tests", function () {
  let oldBridgedEthVersion: number;

  const aliasedGovernanceAddress = ethers.utils.getAddress(
    process.env.ALIASED_GOVERNANCE_ADDRESS || ethers.utils.hexlify(ethers.utils.randomBytes(20))
  );
  const l1ChainId = process.env.L1_CHAIN_ID || 1;
  const bridgedEthAssetId = ethers.utils.keccak256(
    ethers.utils.defaultAbiCoder.encode(
      ["uint256", "address", "bytes32"],
      [l1ChainId, REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS, ethers.utils.hexZeroPad(ethers.utils.hexlify(1), 32)]
    )
  );

  before(async () => {
    // Checking the old system contract owners
    const bridgehub = await ethers.getContractAt("Ownable2Step", REAL_BRIDGEHUB_ADDRESS);
    const oldBridgehubOwner = await bridgehub.owner();
    console.log("Old bridgehub owner:", oldBridgehubOwner);
    if (oldBridgehubOwner === aliasedGovernanceAddress) {
      console.log("Bridgehub is already owned by the aliased governance address");
    }
    const assetRouter = await ethers.getContractAt("Ownable2Step", REAL_L2_ASSET_ROUTER_ADDRESS);
    const oldAssetRouterOwner = await assetRouter.owner();
    console.log("Old asset router owner:", oldAssetRouterOwner);
    if (oldAssetRouterOwner === aliasedGovernanceAddress) {
      console.log("Asset router is already owned by the aliased governance address");
    }
    const l2NativeTokenVaultOwnable = await ethers.getContractAt("Ownable2Step", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
    const oldL2NativeTokenVaultOwner = await l2NativeTokenVaultOwnable.owner();
    console.log("Old L2 native token vault owner:", oldL2NativeTokenVaultOwner);
    if (oldL2NativeTokenVaultOwner === aliasedGovernanceAddress) {
      console.log("L2 native token vault is already owned by the aliased governance address");
    }

    // Getting the old Bridged ETH version, if applicable
    const l2NativeTokenVault = await ethers.getContractAt("IL2NativeTokenVault", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
    const bridgedEthAddress = await l2NativeTokenVault.tokenAddress(bridgedEthAssetId);
    if (bridgedEthAddress !== ethers.constants.AddressZero) {
      const storageValue = await ethers.provider.getStorageAt(bridgedEthAddress, ethers.constants.Zero);
      oldBridgedEthVersion = Number(BigInt(storageValue) & BigInt(0xff));
    }
  });

  describe("upgrade", function () {
    before(async () => {
      const forceDeployer = await ethers.getImpersonatedSigner(REAL_FORCE_DEPLOYER_ADDRESS);
      const complexUpgrader = ComplexUpgraderFactory.connect(REAL_COMPLEX_UPGRADER_CONTRACT_ADDRESS, forceDeployer);

      const l2V29UpgradeFactory = await ethers.getContractFactory("L2V29Upgrade");
      await publishBytecode(l2V29UpgradeFactory.bytecode);
      const proxyAdminFactory = await ethers.getContractFactory("ProxyAdmin");
      await publishBytecode(proxyAdminFactory.bytecode);
      // Creating a dummy deterministic address for deployment
      const dummyDeployAddress = create2Address(
        complexUpgrader.address,
        ethers.utils.hexlify(hashBytecode(l2V29UpgradeFactory.bytecode)),
        ethers.utils.formatBytes32String("L2V29Upgrade"),
        "0x"
      );

      const forceDeployments = [
        {
          bytecodeHash: hashBytecode(l2V29UpgradeFactory.bytecode),
          newAddress: dummyDeployAddress,
          callConstructor: false,
          value: ethers.constants.Zero,
          input: "0x",
        },
      ];

      await complexUpgrader.forceDeployAndUpgrade(
        forceDeployments,
        dummyDeployAddress,
        l2V29UpgradeFactory.interface.encodeFunctionData("upgrade", [aliasedGovernanceAddress, bridgedEthAssetId])
      );
    });

    it("System contracts are owned by the correct governance address", async () => {
      const bridgehub = await ethers.getContractAt("Ownable2Step", REAL_BRIDGEHUB_ADDRESS);
      expect(await bridgehub.owner()).to.equal(aliasedGovernanceAddress);
      const assetRouter = await ethers.getContractAt("Ownable2Step", REAL_L2_ASSET_ROUTER_ADDRESS);
      expect(await assetRouter.owner()).to.equal(aliasedGovernanceAddress);
      const l2NativeTokenVault = await ethers.getContractAt("Ownable2Step", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
      expect(await l2NativeTokenVault.owner()).to.equal(aliasedGovernanceAddress);
    });

    let doesL2LegacySharedBridgeExist = true;
    it("Ownership of legacy shared bridge and its beacon proxy get migrated, if applicable", async function (this: Context) {
      // Migration is only needed if legacy shared bridge exists, test is skipped if not
      const assetRouter = await ethers.getContractAt("IL2AssetRouter", REAL_L2_ASSET_ROUTER_ADDRESS);
      const l2LegacySharedBridge = await assetRouter.L2_LEGACY_SHARED_BRIDGE();
      if (l2LegacySharedBridge === ethers.constants.AddressZero) {
        doesL2LegacySharedBridgeExist = false;
        console.log("Legacy shared bridge does not exist, skipping ownership migration test");
        this.skip();
      }

      // Migrates ownership of the legacy shared bridge's TransparentUpgradeableProxy to the aliased governance address
      const proxyAdminAddressRaw = await ethers.provider.getStorageAt(l2LegacySharedBridge, PROXY_ADMIN_SLOT);
      const proxyAdminAddress = ethers.utils.getAddress("0x" + proxyAdminAddressRaw.slice(-40));
      const proxyAdmin = await ethers.getContractAt("ProxyAdmin", proxyAdminAddress);
      expect(await proxyAdmin.getProxyAdmin(l2LegacySharedBridge)).to.equal(proxyAdminAddress);
      expect(await proxyAdmin.owner()).to.equal(aliasedGovernanceAddress);

      // Migrates ownership of the beacon proxy to the aliased governance address
      const sharedBridgeLegacy = await ethers.getContractAt("IL2SharedBridgeLegacy", l2LegacySharedBridge);
      const l2TokenBeaconAddress = await sharedBridgeLegacy.l2TokenBeacon();
      const l2TokenBeacon = await ethers.getContractAt("UpgradeableBeacon", l2TokenBeaconAddress);
      expect(await l2TokenBeacon.owner()).to.equal(aliasedGovernanceAddress);
    });

    it("The bridged ETH token metadata bug gets patched, if applicable", async function (this: Context) {
      // Test is skipped if legacy shared bridge does not exist
      if (!doesL2LegacySharedBridgeExist) {
        console.log("Legacy shared bridge does not exist, skipping bridged ETH metadata test");
        this.skip();
      }
      // Reinitialized bridged ETH only if it exists
      const l2NativeTokenVault = await ethers.getContractAt("IL2NativeTokenVault", REAL_L2_NATIVE_TOKEN_VAULT_ADDRESS);
      const bridgedEthAddress = await l2NativeTokenVault.tokenAddress(bridgedEthAssetId);
      // Test is skipped if bridged ETH is not defined
      if (bridgedEthAddress === ethers.constants.AddressZero) {
        console.log("Bridged ETH is not defined, skipping bridged ETH metadata test");
        this.skip();
      }

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
  });
});

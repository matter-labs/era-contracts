// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {SettlementLayerV32Upgrade} from "contracts/upgrades/SettlementLayerV32Upgrade.sol";
import {L2UpgradeTxLib} from "contracts/upgrades/L2UpgradeTxLib.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2GenesisUpgrade} from "contracts/state-transition/l2-deps/IL2GenesisUpgrade.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "contracts/bridge/ntv/INativeTokenVaultBase.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {UnexpectedUpgradeSelector} from "contracts/common/L1ContractErrors.sol";
import {UnexpectedZKsyncOSFlag} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";

/// @notice Tests the v32 per-chain rewrite of the committed L2 upgrade transaction: chainId and
///         chain-specific force-deployment data are injected into the `L2GenesisUpgrade` calldata
///         while everything ecosystem-wide (deployments, delegate, fixed data) is preserved.
/// @dev The bridgehub/NTV lookups of `buildChainSpecificForceDeploymentsData` are mocked (ETH
///      base token path): this test isolates the calldata rewrite; the L1 state around it is
///      covered by the registry-driven and v31 upgrade tests.
contract SettlementLayerV32UpgradeTest is Test {
    SettlementLayerV32Upgrade internal upgradeContract;

    address internal bridgehub = makeAddr("bridgehub");
    address internal assetRouter = makeAddr("assetRouter");
    address internal nativeTokenVault = makeAddr("nativeTokenVault");
    address internal ctmDeployer = makeAddr("ctmDeployer");

    uint256 internal constant CHAIN_ID = 555;
    bytes32 internal constant BASE_TOKEN_ASSET_ID = bytes32(uint256(0xabc123));

    function setUp() public {
        upgradeContract = new SettlementLayerV32Upgrade();

        vm.mockCall(bridgehub, abi.encodeWithSelector(IBridgehubBase.assetRouter.selector), abi.encode(assetRouter));
        vm.mockCall(
            assetRouter,
            abi.encodeWithSelector(IL1AssetRouter.nativeTokenVault.selector),
            abi.encode(nativeTokenVault)
        );
        vm.mockCall(
            bridgehub,
            abi.encodeWithSelector(IBridgehubBase.baseTokenAssetId.selector, CHAIN_ID),
            abi.encode(BASE_TOKEN_ASSET_ID)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originToken.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(ETH_TOKEN_ADDRESS)
        );
        vm.mockCall(
            nativeTokenVault,
            abi.encodeWithSelector(INativeTokenVaultBase.originChainId.selector, BASE_TOKEN_ASSET_ID),
            abi.encode(uint256(1))
        );
    }

    function _placeholderTxData(bool _isZKsyncOS) internal view returns (bytes memory) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        deployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
            deployedBytecodeInfo: hex"aa01",
            newAddress: address(0x10002)
        });
        return
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (
                    deployments,
                    L2_GENESIS_UPGRADE_ADDR,
                    // chainId and additionalForceDeploymentsData are placeholders (zero/empty).
                    abi.encodeCall(IL2GenesisUpgrade.genesisUpgrade, (_isZKsyncOS, 0, ctmDeployer, hex"f1f2", ""))
                )
            );
    }

    function test_getL2UpgradeTxData_injectsPerChainArguments() public view {
        bytes memory rewritten = upgradeContract.getL2UpgradeTxData(
            bridgehub,
            CHAIN_ID,
            false,
            _placeholderTxData(false)
        );

        assertEq(bytes4(rewritten), IComplexUpgrader.forceDeployAndUpgradeUniversal.selector);
        bytes memory args = new bytes(rewritten.length - 4);
        for (uint256 i = 0; i < args.length; ++i) {
            args[i] = rewritten[i + 4];
        }
        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments,
            address delegateTo,
            bytes memory genesisCalldata
        ) = abi.decode(args, (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));

        // Ecosystem-wide parts are preserved.
        assertEq(deployments.length, 1);
        assertEq(deployments[0].deployedBytecodeInfo, hex"aa01");
        assertEq(delegateTo, L2_GENESIS_UPGRADE_ADDR);

        assertEq(bytes4(genesisCalldata), IL2GenesisUpgrade.genesisUpgrade.selector);
        bytes memory genesisArgs = new bytes(genesisCalldata.length - 4);
        for (uint256 i = 0; i < genesisArgs.length; ++i) {
            genesisArgs[i] = genesisCalldata[i + 4];
        }
        (
            bool isZKsyncOS,
            uint256 chainId,
            address decodedCtmDeployer,
            bytes memory fixedData,
            bytes memory additional
        ) = abi.decode(genesisArgs, (bool, uint256, address, bytes, bytes));

        assertFalse(isZKsyncOS);
        assertEq(decodedCtmDeployer, ctmDeployer);
        assertEq(fixedData, hex"f1f2");
        // The per-chain placeholders were injected.
        assertEq(chainId, CHAIN_ID);
        assertEq(additional, L2UpgradeTxLib.buildChainSpecificForceDeploymentsData(bridgehub, CHAIN_ID));
    }

    function test_revertWhen_outerSelectorWrong() public {
        vm.expectRevert(UnexpectedUpgradeSelector.selector);
        upgradeContract.getL2UpgradeTxData(bridgehub, CHAIN_ID, false, hex"deadbeef");
    }

    function test_revertWhen_zksyncOSFlagMismatched() public {
        // The committed calldata says ZKsyncOS but the chain is an Era chain.
        vm.expectRevert(abi.encodeWithSelector(UnexpectedZKsyncOSFlag.selector, false, true));
        upgradeContract.getL2UpgradeTxData(bridgehub, CHAIN_ID, false, _placeholderTxData(true));
    }
}

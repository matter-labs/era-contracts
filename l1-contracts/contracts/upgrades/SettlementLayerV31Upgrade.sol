// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {L2_VERSION_SPECIFIC_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";
import {IL2V31Upgrade} from "./IL2V31Upgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {IL2ContractDeployer} from "../common/interfaces/IL2ContractDeployer.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IL1MessageRoot} from "../core/message-root/IL1MessageRoot.sol";
import {IChainTypeManager} from "../state-transition/IChainTypeManager.sol";
import {Bytes} from "../vendor/Bytes.sol";

error PriorityQueueNotReady();
error V31UpgradeGatewayBlockNumberNotSet();
error NotAllBatchesExecuted();
error UnsupportedL2UpgradeSelector(bytes4 selector);
error UnexpectedUpgradeTarget(address target);

event L2V31UpgradeCalldataConstructed(address indexed bridgehub, uint256 indexed chainId, bytes data);

/// @author Matter Labs
/// @title This contract will only be used on L1, since for V31 there will be no active GW, due the deprecation of EraGW, and the ZKSync OS GW launch will only happen after V31.
/// @custom:security-contact security@matterlabs.dev
contract SettlementLayerV31Upgrade is BaseZkSyncUpgrade {
    using Bytes for bytes;

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        IBridgehubBase bridgehub = IBridgehubBase(s.bridgehub);
        address assetRouter = address(bridgehub.assetRouter());
        address nativeTokenVaultAddr = address(IL1AssetRouter(assetRouter).nativeTokenVault());

        /// We write to storage to avoid reentrancy.
        s.nativeTokenVault = nativeTokenVaultAddr;

        // Note that this call will revert if the native token vault has not been upgraded, i.e.
        // if a chain settling on Gateway tries to upgrade before ZK Gateway has done the upgrade.
        s.assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());
        s.__DEPRECATED_l2DAValidator = address(0);

        // Set the permissionless validator used in Priority Mode, same as done in DiamondInit.
        s.priorityModeInfo.permissionlessValidator = IChainTypeManager(s.chainTypeManager).PERMISSIONLESS_VALIDATOR();

        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        bytes memory l2V31UpgradeCalldata = getL2V31UpgradeCalldata(address(bridgehub), s.chainId);
        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        bytes4 selector = bytes4(proposedUpgrade.l2ProtocolUpgradeTx.data);

        if (selector == IComplexUpgrader.forceDeployAndUpgrade.selector) {
            (
                IL2ContractDeployer.ForceDeployment[] memory forceDeployments,
                address delegateTo,
                bytes memory existingUpgradeCalldata
            ) = abi.decode(
                proposedUpgrade.l2ProtocolUpgradeTx.data.slice(4),
                (IL2ContractDeployer.ForceDeployment[], address, bytes)
            );

            if (bytes4(existingUpgradeCalldata) != IL2V31Upgrade.upgrade.selector) {
                revert UnsupportedL2UpgradeSelector(bytes4(existingUpgradeCalldata));
            }
            if (delegateTo != L2_VERSION_SPECIFIC_UPGRADER_ADDR) {
                revert UnexpectedUpgradeTarget(delegateTo);
            }

            proposedUpgrade.l2ProtocolUpgradeTx.data = abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgrade,
                (forceDeployments, delegateTo, l2V31UpgradeCalldata)
            );
        } else if (selector == IComplexUpgrader.upgrade.selector) {
            (address delegateTo, bytes memory existingUpgradeCalldata) = abi.decode(
                proposedUpgrade.l2ProtocolUpgradeTx.data.slice(4),
                (address, bytes)
            );

            if (bytes4(existingUpgradeCalldata) != IL2V31Upgrade.upgrade.selector) {
                revert UnsupportedL2UpgradeSelector(bytes4(existingUpgradeCalldata));
            }
            if (delegateTo != L2_VERSION_SPECIFIC_UPGRADER_ADDR) {
                revert UnexpectedUpgradeTarget(delegateTo);
            }

            proposedUpgrade.l2ProtocolUpgradeTx.data = abi.encodeCall(
                IComplexUpgrader.upgrade,
                (delegateTo, l2V31UpgradeCalldata)
            );
        } else {
            revert UnsupportedL2UpgradeSelector(selector);
        }

        super.upgrade(proposedUpgrade);
        IMessageRootBase messageRoot = IMessageRootBase(bridgehub.messageRoot());

        if (s.settlementLayer == address(0)) {
            // slither-disable-next-line reentrancy-no-eth
            IL1MessageRoot(address(messageRoot)).saveV31UpgradeChainBatchNumber(s.chainId);
        }

        if (bridgehub.whitelistedSettlementLayers(s.chainId)) {
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        // Era chains automatically have it tracked.
        // ZKsync OS chains haven't been tracking this value until the v31 upgrade.
        // It will have to be backfilled.
        // FIXME The actual logic for backfilling will be introduced in a separate PR.
        if (!s.zksyncOS) {
            s.baseTokenHasTotalSupply = true;
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function getL2V31UpgradeCalldata(address _bridgehub, uint256 _chainId) public view returns (bytes memory) {
        IBridgehubBase bridgehub = IBridgehubBase(_bridgehub);
        address assetRouter = address(bridgehub.assetRouter());
        address nativeTokenVaultAddr = address(IL1AssetRouter(assetRouter).nativeTokenVault());
        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(_chainId);
        INativeTokenVaultBase nativeTokenVault = INativeTokenVaultBase(nativeTokenVaultAddr);

        return
            abi.encodeCall(
                IL2V31Upgrade.upgrade,
                (
                    nativeTokenVault.originChainId(baseTokenAssetId),
                    nativeTokenVault.originToken(baseTokenAssetId)
                )
            );
    }

    function emitL2V31UpgradeCalldata(address _bridgehub, uint256 _chainId) external returns (bytes memory data) {
        data = getL2V31UpgradeCalldata(_bridgehub, _chainId);
        emit L2V31UpgradeCalldataConstructed(_bridgehub, _chainId, data);
    }
}

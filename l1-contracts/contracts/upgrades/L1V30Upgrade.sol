// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IMessageRoot} from "../bridgehub/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IChainAssetHandler} from "../bridgehub/IChainAssetHandler.sol";
import {INativeTokenVault} from "../bridge/ntv/INativeTokenVault.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";
import {IL2V30Upgrade} from "./IL2V30Upgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";

error PriorityQueueNotReady();
error V30UpgradeGatewayBlockNumberNotSet();

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Note, that this upgrade is run wherever the settlement layer of the chain is, i.e. 
/// on L1 if the chain settles there or on the ZK Gateway.
contract L1V30Upgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        IBridgehub bridgehub = IBridgehub(s.bridgehub);
        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(s.chainId);
        INativeTokenVault nativeTokenVault = INativeTokenVault(
            IL1AssetRouter(bridgehub.assetRouter()).nativeTokenVault()
        );

        uint256 baseTokenOriginChainId = nativeTokenVault.originChainId(baseTokenAssetId);
        address baseTokenOriginAddress = nativeTokenVault.originToken(baseTokenAssetId);
        bytes memory l2GenesisUpgradeCalldata = abi.encodeCall(
            IL2V30Upgrade.upgrade,
            (baseTokenOriginChainId, baseTokenOriginAddress)
        );
        bytes memory complexUpgraderCalldata = abi.encodeCall(
            IComplexUpgrader.upgrade,
            (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata)
        );
        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        proposedUpgrade.l2ProtocolUpgradeTx.data = complexUpgraderCalldata;
        this.upgradeInner(proposedUpgrade);

        IChainAssetHandler chainAssetHandler = IChainAssetHandler(bridgehub.chainAssetHandler());
        IMessageRoot messageRoot = IMessageRoot(bridgehub.messageRoot());

        chainAssetHandler.setMigrationNumberForV30(s.chainId);

        s.nativeTokenVault = address(IL1AssetRouter(bridgehub.assetRouter()).nativeTokenVault());
        // Note, that this call will revert if the native token vault has not been upgraded, i.e. 
        // if a chain settling on Gateway tries to upgrade before ZK Gateway has done the upgrade.
        s.assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());

        // Note, that the line below ensures that chains can only upgrade once the ZK Gateway itself is upgraded,
        // i.e. its `v30UpgradeGatewayBlockNumber` is non zero.
        if (s.settlementLayer == address(0)) {
            messageRoot.saveV30UpgradeChainBatchNumber(s.chainId);
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice the upgrade function.
    function upgradeInner(ProposedUpgrade calldata _proposedUpgrade) public returns (bytes32) {
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

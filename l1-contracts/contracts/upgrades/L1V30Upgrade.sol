// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {L2_MESSAGE_ROOT, L2_MESSAGE_ROOT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
import {IMessageRoot} from "../bridgehub/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IChainAssetHandler} from "../bridgehub/IChainAssetHandler.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";

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
        IChainAssetHandler chainAssetHandler = IChainAssetHandler(bridgehub.chainAssetHandler());
        /// This is called only at the settlement of the chain.
        if (s.settlementLayer == address(0)) {
            chainAssetHandler.setMigrationNumberForV30(s.chainId);
        }
        super.upgrade(_proposedUpgrade);

        s.nativeTokenVault = address(IL1AssetRouter(bridgehub.assetRouter()).nativeTokenVault());
        // Note, that this call will revert if the native token vault has not been upgraded, i.e. 
        // if a chain settling on Gateway tries to upgrade before ZK Gateway has done the upgrade.
        s.assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());

        // Note, that the line below ensures that chains can only upgrade once the ZK Gateway itself is upgraded,
        // i.e. its `v30UpgradeGatewayBlockNumber` is non zero.
        uint256 v30UpgradeGatewayBlockNumber = (IBridgehub(s.bridgehub).messageRoot()).v30UpgradeGatewayBlockNumber();
        // At the time of the upgrade, it is assumed that only one whitelisted settlement layer exists, i.e. 
        // the EraVM-based ZK Gateway.
        // For ZK Gateway itself, this value (i.e. v30UpgradeGatewayBlockNumber) is set inside the constructor o the MessageRoot.
        if (!bridgehub.whitelistedSettlementLayers(s.chainId)) {
            require(v30UpgradeGatewayBlockNumber != 0, V30UpgradeGatewayBlockNumberNotSet());
            IMailbox(address(this)).requestL2ServiceTransaction(
                L2_MESSAGE_ROOT_ADDR,
                abi.encodeCall(L2_MESSAGE_ROOT.saveV30UpgradeGatewayBlockNumberOnL2, v30UpgradeGatewayBlockNumber)
            );
        }
        IMessageRoot messageRoot = IMessageRoot(bridgehub.messageRoot());
        messageRoot.saveV30UpgradeChainBatchNumber(s.chainId);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

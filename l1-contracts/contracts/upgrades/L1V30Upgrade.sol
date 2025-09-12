// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehub} from "../bridgehub/IBridgehub.sol";
import {L2_GENESIS_UPGRADE_ADDR, L2_MESSAGE_ROOT, L2_MESSAGE_ROOT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IMailbox} from "../state-transition/chain-interfaces/IMailbox.sol";
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
        s.assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());

        uint256 v30UpgradeGatewayBlockNumber = (IBridgehub(s.bridgehub).messageRoot()).v30UpgradeGatewayBlockNumber();
        if (s.chainId !=  messageRoot.GATEWAY_CHAIN_ID()) {
            require(v30UpgradeGatewayBlockNumber != 0, V30UpgradeGatewayBlockNumberNotSet());
            IMailbox(address(this)).requestL2ServiceTransaction(
                L2_MESSAGE_ROOT_ADDR,
                abi.encodeCall(L2_MESSAGE_ROOT.saveV30UpgradeGatewayBlockNumberOnL2, v30UpgradeGatewayBlockNumber)
            );
        }
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

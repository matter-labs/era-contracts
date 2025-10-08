// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehubBase} from "../bridgehub/IBridgehubBase.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IMessageRoot} from "../bridgehub/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IChainAssetHandler} from "../bridgehub/IChainAssetHandler.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";
import {IL2V30Upgrade} from "./IL2V30Upgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";

error PriorityQueueNotReady();
error V30UpgradeGatewayBlockNumberNotSet();
error GWNotV30(uint256 chainId);
error NotAllBatchesExecuted();

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract SettlementLayerV30Upgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        IBridgehubBase bridgehub = IBridgehubBase(s.bridgehub);

        /// We write to storage to avoid reentrancy.
        s.nativeTokenVault = address(IL1AssetRouter(bridgehub.assetRouter()).nativeTokenVault());

        // Note that this call will revert if the native token vault has not been upgraded, i.e.
        // if a chain settling on Gateway tries to upgrade before ZK Gateway has done the upgrade.
        s.assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());
        s.__DEPRECATED_l2DAValidator = address(0);

        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(s.chainId);
        INativeTokenVaultBase nativeTokenVault = INativeTokenVaultBase(
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
        super.upgrade(proposedUpgrade);
        IChainAssetHandler chainAssetHandler = IChainAssetHandler(bridgehub.chainAssetHandler());
        IMessageRoot messageRoot = IMessageRoot(bridgehub.messageRoot());

        // The lines below ensure that chains can only upgrade once the ZK Gateway itself is upgraded,
        // i.e. its minor protocol version is at least 30. Note, we use The tuple of (major, minor, patch)
        // to denote protocol version.
        uint256 gwChainId = messageRoot.ERA_GATEWAY_CHAIN_ID();
        address gwChain = bridgehub.getZKChain(gwChainId);
        // slither-disable-next-line unused-return
        (, uint256 gwMinor, ) = IGetters(gwChain).getSemverProtocolVersion();
        require(gwMinor >= 30, GWNotV30(gwChainId));

        chainAssetHandler.setMigrationNumberForV30(s.chainId);

        if (s.settlementLayer == address(0)) {
            messageRoot.saveV30UpgradeChainBatchNumber(s.chainId);
        }

        if (bridgehub.whitelistedSettlementLayers(s.chainId)) {
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

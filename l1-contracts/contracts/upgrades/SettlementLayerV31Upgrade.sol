// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IBridgehubBase} from "../core/bridgehub/IBridgehubBase.sol";
import {L2_GENESIS_UPGRADE_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {IMessageRootBase} from "../core/message-root/IMessageRoot.sol";
import {IL1AssetRouter} from "../bridge/asset-router/IL1AssetRouter.sol";
import {IChainAssetHandlerBase} from "../core/chain-asset-handler/IChainAssetHandler.sol";
import {INativeTokenVaultBase} from "../bridge/ntv/INativeTokenVaultBase.sol";
import {IL1NativeTokenVault} from "../bridge/ntv/IL1NativeTokenVault.sol";
import {IL2V31Upgrade} from "./IL2V31Upgrade.sol";
import {IComplexUpgrader} from "../state-transition/l2-deps/IComplexUpgrader.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";
import {IL1MessageRoot} from "../core/message-root/IL1MessageRoot.sol";

error PriorityQueueNotReady();
error V31UpgradeGatewayBlockNumberNotSet();
error GWNotV31(uint256 chainId);
error NotAllBatchesExecuted();

/// @author Matter Labs
/// @title This contract will only be used on L1, since for V31 there will be no active GW, due the deprecation of EraGW, and the ZKSync OS GW launch will only happen after V31.
/// @custom:security-contact security@matterlabs.dev
contract SettlementLayerV31Upgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        IBridgehubBase bridgehub = IBridgehubBase(s.bridgehub);

        /// We write to storage to avoid reentrancy.
        s.nativeTokenVault = address(IL1AssetRouter(address(bridgehub.assetRouter())).nativeTokenVault());

        // Note that this call will revert if the native token vault has not been upgraded, i.e.
        // if a chain settling on Gateway tries to upgrade before ZK Gateway has done the upgrade.
        s.assetTracker = address(IL1NativeTokenVault(s.nativeTokenVault).l1AssetTracker());
        s.__DEPRECATED_l2DAValidator = address(0);

        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        bytes32 baseTokenAssetId = bridgehub.baseTokenAssetId(s.chainId);
        INativeTokenVaultBase nativeTokenVault = INativeTokenVaultBase(
            IL1AssetRouter(address(bridgehub.assetRouter())).nativeTokenVault()
        );

        uint256 baseTokenOriginChainId = nativeTokenVault.originChainId(baseTokenAssetId);
        address baseTokenOriginAddress = nativeTokenVault.originToken(baseTokenAssetId);
        bytes memory l2GenesisUpgradeCalldata = abi.encodeCall(
            IL2V31Upgrade.upgrade,
            (baseTokenOriginChainId, baseTokenOriginAddress)
        );
        bytes memory complexUpgraderCalldata = abi.encodeCall(
            IComplexUpgrader.upgrade,
            (L2_GENESIS_UPGRADE_ADDR, l2GenesisUpgradeCalldata)
        );
        ProposedUpgrade memory proposedUpgrade = _proposedUpgrade;
        proposedUpgrade.l2ProtocolUpgradeTx.data = complexUpgraderCalldata;
        super.upgrade(proposedUpgrade);
        IChainAssetHandlerBase chainAssetHandler = IChainAssetHandlerBase(bridgehub.chainAssetHandler());
        IMessageRootBase messageRoot = bridgehub.messageRoot();

        // The lines below ensure that chains can only upgrade once the ZK Gateway itself is upgraded,
        // i.e. its minor protocol version is at least 30. Note, we use The tuple of (major, minor, patch)
        // to denote protocol version.
        uint256 gwChainId = messageRoot.ERA_GATEWAY_CHAIN_ID();
        address gwChain = bridgehub.getZKChain(gwChainId);
        // slither-disable-next-line unused-return
        (, uint256 gwMinor, ) = IGetters(gwChain).getSemverProtocolVersion();
        require(gwMinor >= 30, GWNotV31(gwChainId));

        chainAssetHandler.setMigrationNumberForV31(s.chainId);

        if (s.settlementLayer == address(0)) {
            IL1MessageRoot(address(messageRoot)).saveV31UpgradeChainBatchNumber(s.chainId);
        }

        if (bridgehub.whitelistedSettlementLayers(s.chainId)) {
            require(IGetters(address(this)).getPriorityQueueSize() == 0, PriorityQueueNotReady());
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

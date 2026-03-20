// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {
    L2_ASSET_TRACKER_ADDR,
    L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR,
    L2_NATIVE_TOKEN_VAULT_ADDR
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L2AssetTracker} from "../bridge/asset-tracker/L2AssetTracker.sol";
import {IL2AssetTracker} from "../bridge/asset-tracker/IL2AssetTracker.sol";
import {L2NativeTokenVault} from "../bridge/ntv/L2NativeTokenVault.sol";
import {MissingBaseTokenAssetId} from "../bridge/asset-tracker/AssetTrackerErrors.sol";
import {TokenBridgingData, TokenMetadata} from "../common/Messaging.sol";
import {IL2BaseTokenBase} from "../l2-system/interfaces/IL2BaseTokenBase.sol";
import {V31AcrossRecovery} from "./V31AcrossRecovery.sol";
import {IL2V31Upgrade} from "../upgrades/IL2V31Upgrade.sol";

/// @custom:security-contact security@matterlabs.dev
/// @author Matter Labs
/// @title L2V31Upgrade, contains v31 upgrade fixes.
/// @dev This contract is neither predeployed nor a system contract. It resides in this folder to facilitate code reuse.
/// @dev This contract is called during the forceDeployAndUpgrade function of the ComplexUpgrader system contract.
contract L2V31Upgrade is V31AcrossRecovery, IL2V31Upgrade {
    /// @inheritdoc IL2V31Upgrade
    function upgrade(
        uint256 _baseTokenOriginChainId,
        address _baseTokenOriginAddress,
        string calldata _baseTokenName,
        string calldata _baseTokenSymbol,
        uint256 _baseTokenDecimals
    ) external {
        acrossRecovery();

        bytes32 baseTokenAssetId = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR).BASE_TOKEN_ASSET_ID();
        if (baseTokenAssetId == bytes32(0)) {
            revert MissingBaseTokenAssetId();
        }

        _updateNativeTokenVault(
            baseTokenAssetId,
            _baseTokenOriginChainId,
            _baseTokenOriginAddress,
            _baseTokenName,
            _baseTokenSymbol,
            _baseTokenDecimals
        );

        // Register the base token in the asset tracker.
        IL2AssetTracker(L2_ASSET_TRACKER_ADDR).registerBaseTokenDuringUpgrade();

        // Initialize the L2BaseToken (sets L1_CHAIN_ID and BaseTokenHolder balance).
        IL2BaseTokenBase(L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR).initL2(
            L2AssetTracker(L2_ASSET_TRACKER_ADDR).L1_CHAIN_ID()
        );
    }

    function _updateNativeTokenVault(
        bytes32 _baseTokenAssetId,
        uint256 _baseTokenOriginChainId,
        address _baseTokenOriginAddress,
        string calldata _baseTokenName,
        string calldata _baseTokenSymbol,
        uint256 _baseTokenDecimals
    ) internal {
        L2NativeTokenVault nativeTokenVault = L2NativeTokenVault(L2_NATIVE_TOKEN_VAULT_ADDR);
        nativeTokenVault.updateL2(
            nativeTokenVault.L1_CHAIN_ID(),
            nativeTokenVault.L2_TOKEN_PROXY_BYTECODE_HASH(),
            address(nativeTokenVault.L2_LEGACY_SHARED_BRIDGE()),
            nativeTokenVault.WETH_TOKEN(),
            _getBaseTokenBridgingData(_baseTokenAssetId, _baseTokenOriginChainId, _baseTokenOriginAddress),
            _getBaseTokenMetadata(_baseTokenName, _baseTokenSymbol, _baseTokenDecimals)
        );
    }

    function _getBaseTokenBridgingData(
        bytes32 _assetId,
        uint256 _originChainId,
        address _originToken
    ) internal pure returns (TokenBridgingData memory) {
        return TokenBridgingData({assetId: _assetId, originChainId: _originChainId, originToken: _originToken});
    }

    function _getBaseTokenMetadata(
        string calldata _name,
        string calldata _symbol,
        uint256 _decimals
    ) internal pure returns (TokenMetadata memory) {
        return TokenMetadata({name: _name, symbol: _symbol, decimals: _decimals});
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";

/// @notice Drives `L1NativeTokenVault.populateBridgedOut` over every L1-native asset, which is what makes
/// withdrawals of those assets work again after an in-place upgrade onto the `bridgedOut` accounting.
/// See {protocol-docs/bridging.md#populating-bridgedout-during-an-in-place-upgrade}.
/// @dev Callable by any EOA — the amounts come from legacy storage that nothing writes anymore, so the
/// caller cannot influence them. Version-neutral: usable by any pre-v32 -> v32 upgrade script.
library BridgedOutPopulationLib {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Assets per `populateBridgedOut` call. Keeps a single transaction well inside a block even for
    ///      ecosystems with many registered tokens; overridable via `BRIDGED_OUT_ASSETS_PER_CALL`.
    uint256 internal constant DEFAULT_ASSETS_PER_CALL = 25;

    /// @notice Populates `bridgedOut` for every L1-native asset that still has a legacy amount, taking its
    /// batch size from the environment.
    /// @param _bridgehub The L1 bridgehub, used to discover the NTV.
    /// @return assetIds The L1-native assets that were considered.
    /// @return populatedPerAsset Per entry of `assetIds`, the amount folded into that asset's `bridgedOut`.
    function populateBridgedOutForAllAssets(
        address _bridgehub
    ) internal returns (bytes32[] memory assetIds, uint256[] memory populatedPerAsset) {
        return
            populateBridgedOutForAllAssets(
                _bridgehub,
                vm.envOr("BRIDGED_OUT_ASSETS_PER_CALL", DEFAULT_ASSETS_PER_CALL)
            );
    }

    /// @notice Populates `bridgedOut` with an explicit batch size.
    /// @param _bridgehub The L1 bridgehub, used to discover the NTV.
    /// @param _assetsPerCall Maximum number of assets per `populateBridgedOut` call.
    /// @return assetIds The L1-native assets that were considered.
    /// @return populatedPerAsset Per entry of `assetIds`, the amount folded into that asset's `bridgedOut`.
    function populateBridgedOutForAllAssets(
        address _bridgehub,
        uint256 _assetsPerCall
    ) internal returns (bytes32[] memory assetIds, uint256[] memory populatedPerAsset) {
        require(_assetsPerCall != 0, "assets per call must be non-zero");

        IL1NativeTokenVault ntv = _nativeTokenVault(_bridgehub);
        assetIds = _l1NativeAssetIds(ntv);
        populatedPerAsset = new uint256[](assetIds.length);

        console.log("Populating bridgedOut. L1-native assets found in the NTV:", assetIds.length);
        console.log("Legacy L1 asset tracker:", ntv.legacyL1AssetTracker());

        uint256[] memory pending = _pendingAssetIndexes(ntv, assetIds);
        if (pending.length == 0) {
            console.log("Nothing left to populate");
            return (assetIds, populatedPerAsset);
        }
        console.log("Assets with a legacy amount left to populate:", pending.length);

        for (uint256 offset = 0; offset < pending.length; offset += _assetsPerCall) {
            uint256 batchLength = pending.length - offset < _assetsPerCall ? pending.length - offset : _assetsPerCall;
            bytes32[] memory batch = new bytes32[](batchLength);
            for (uint256 i = 0; i < batchLength; ++i) {
                batch[i] = assetIds[pending[offset + i]];
            }

            uint256[] memory populatedAmounts = ntv.populateBridgedOut(batch);
            for (uint256 i = 0; i < batchLength; ++i) {
                populatedPerAsset[pending[offset + i]] = populatedAmounts[i];
            }
        }

        _logPerAssetTotals(ntv, assetIds, populatedPerAsset);
    }

    /// @notice Indexes into `_assetIds` of the assets that are not populated yet and have a legacy amount.
    /// @dev Assets with a zero legacy amount are dropped: populating them would only burn gas on writing the
    ///      "already populated" flag, since a later call would add zero anyway.
    function _pendingAssetIndexes(
        IL1NativeTokenVault _ntv,
        bytes32[] memory _assetIds
    ) private view returns (uint256[] memory pending) {
        uint256[] memory buffer = new uint256[](_assetIds.length);
        uint256 count;

        for (uint256 i = 0; i < _assetIds.length; ++i) {
            bytes32 assetId = _assetIds[i];
            if (_ntv.isAssetTracked(assetId)) {
                continue;
            }
            if (_ntv.legacyBridgedOut(assetId) == 0) {
                continue;
            }
            buffer[count] = i;
            ++count;
        }

        pending = new uint256[](count);
        for (uint256 i = 0; i < count; ++i) {
            pending[i] = buffer[i];
        }
    }

    /// @notice All asset IDs known to the NTV that are native to L1.
    /// @dev The vault's `bridgedTokens` enumeration is the only on-chain list of its assets. Legacy tokens
    ///      that predate the enumeration must be backfilled into it (see
    ///      `TokenMigrationUtils.registerBridgedTokensInNTV`) before this runs, otherwise their amounts stay
    ///      unpopulated and their withdrawals keep reverting.
    function _l1NativeAssetIds(IL1NativeTokenVault _ntv) private view returns (bytes32[] memory assetIds) {
        uint256 tokenCount = _ntv.bridgedTokensCount();
        bytes32[] memory buffer = new bytes32[](tokenCount);
        uint256 count;

        for (uint256 i = 0; i < tokenCount; ++i) {
            bytes32 assetId = _ntv.bridgedTokens(i);
            if (_ntv.originChainId(assetId) != block.chainid) {
                continue;
            }
            buffer[count] = assetId;
            ++count;
        }

        assetIds = new bytes32[](count);
        for (uint256 i = 0; i < count; ++i) {
            assetIds[i] = buffer[i];
        }
    }

    /// @dev Amounts are only ever comparable per asset, so the run is reported that way rather than as a
    ///      single cross-asset total.
    function _logPerAssetTotals(
        IL1NativeTokenVault _ntv,
        bytes32[] memory _assetIds,
        uint256[] memory _populatedPerAsset
    ) private view {
        console.log("bridgedOut population complete. Populated amounts per asset:");
        for (uint256 i = 0; i < _assetIds.length; ++i) {
            if (_populatedPerAsset[i] == 0) {
                continue;
            }
            console.logBytes32(_assetIds[i]);
            console.log("    populated:", _populatedPerAsset[i]);
            console.log("    bridgedOut now:", _ntv.bridgedOut(_assetIds[i]));
        }
    }

    function _nativeTokenVault(address _bridgehub) private view returns (IL1NativeTokenVault) {
        return
            IL1NativeTokenVault(
                address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault())
            );
    }
}

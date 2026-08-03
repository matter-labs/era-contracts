// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable no-console, gas-custom-errors

import {console2 as console} from "forge-std/Script.sol";
import {VmSafe} from "forge-std/Vm.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1AssetRouter} from "contracts/bridge/asset-router/IL1AssetRouter.sol";
import {IL1NativeTokenVault} from "contracts/bridge/ntv/IL1NativeTokenVault.sol";
import {ILegacyL1AssetTracker} from "contracts/bridge/asset-tracker/ILegacyL1AssetTracker.sol";
import {MAX_TOKEN_BALANCE} from "contracts/bridge/asset-tracker/IL2AssetTracker.sol";

/// @notice Drives `L1NativeTokenVault.populateBridgedOut` across every registered chain, which is what
/// makes withdrawals of L1-native assets work again after an in-place upgrade onto the `bridgedOut`
/// accounting. See {protocol-docs/bridging.md#populating-bridgedout-during-an-in-place-upgrade}.
/// @dev Callable by any EOA — the amounts come from frozen legacy storage, so the caller cannot influence
/// them. Version-neutral: usable by any pre-v32 -> v32 upgrade script.
library BridgedOutPopulationLib {
    VmSafe private constant vm = VmSafe(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @dev Assets per `populateBridgedOut` call. Keeps a single transaction well inside a block even for
    ///      ecosystems with many registered tokens; overridable via `BRIDGED_OUT_ASSETS_PER_CALL`.
    uint256 internal constant DEFAULT_ASSETS_PER_CALL = 25;

    /// @notice Populates `bridgedOut` for every (registered chain, L1-native asset) pair with a non-zero
    /// legacy amount, taking its settings from the environment.
    /// @param _bridgehub The L1 bridgehub, used to discover the NTV and the registered chains.
    /// @return assetIds The L1-native assets that were considered.
    /// @return populatedPerAsset Per entry of `assetIds`, the amount folded into that asset's `bridgedOut`
    /// across all chains.
    function populateBridgedOutForAllChains(
        address _bridgehub
    ) internal returns (bytes32[] memory assetIds, uint256[] memory populatedPerAsset) {
        return
            populateBridgedOutForAllChains(
                _bridgehub,
                vm.envOr("BRIDGED_OUT_ASSETS_PER_CALL", DEFAULT_ASSETS_PER_CALL),
                vm.envOr("BRIDGED_OUT_SKIP_INVARIANT_CHECK", false)
            );
    }

    /// @notice Populates `bridgedOut` with explicit settings.
    /// @param _bridgehub The L1 bridgehub, used to discover the NTV and the registered chains.
    /// @param _assetsPerCall Maximum number of assets per `populateBridgedOut` call.
    /// @param _skipInvariantCheck Populate even if the legacy totals cross-check fails.
    /// @return assetIds The L1-native assets that were considered.
    /// @return populatedPerAsset Per entry of `assetIds`, the amount folded into that asset's `bridgedOut`
    /// across all chains.
    function populateBridgedOutForAllChains(
        address _bridgehub,
        uint256 _assetsPerCall,
        bool _skipInvariantCheck
    ) internal returns (bytes32[] memory assetIds, uint256[] memory populatedPerAsset) {
        require(_assetsPerCall != 0, "assets per call must be non-zero");

        IL1NativeTokenVault ntv = _nativeTokenVault(_bridgehub);
        uint256[] memory chainIds = IBridgehubBase(_bridgehub).getAllZKChainChainIDs();
        assetIds = _l1NativeAssetIds(ntv);
        populatedPerAsset = new uint256[](assetIds.length);

        console.log("Populating bridgedOut. Chains:", chainIds.length);
        console.log("L1-native assets found in the NTV:", assetIds.length);
        console.log("Legacy L1 asset tracker:", ntv.legacyL1AssetTracker());

        _checkLegacyTotalsInvariant(ntv, chainIds, assetIds, _skipInvariantCheck);

        for (uint256 i = 0; i < chainIds.length; ++i) {
            _populateBridgedOutForChain(ntv, chainIds[i], assetIds, _assetsPerCall, populatedPerAsset);
        }

        _logPerAssetTotals(ntv, assetIds, populatedPerAsset);
    }

    /// @notice Populates `bridgedOut` for a single chain, batching the assets across several calls.
    /// @param _ntv The L1 native token vault.
    /// @param _chainId The chain whose legacy amounts are folded in.
    /// @param _assetIds The L1-native assets to consider.
    /// @param _assetsPerCall Maximum number of assets per `populateBridgedOut` call.
    /// @param _populatedPerAsset Accumulator, indexed like `_assetIds`, that this call adds to.
    function _populateBridgedOutForChain(
        IL1NativeTokenVault _ntv,
        uint256 _chainId,
        bytes32[] memory _assetIds,
        uint256 _assetsPerCall,
        uint256[] memory _populatedPerAsset
    ) private {
        uint256[] memory pending = _pendingAssetIndexes(_ntv, _chainId, _assetIds);
        if (pending.length == 0) {
            return;
        }

        console.log("  Chain:", _chainId);
        console.log("  Assets with a legacy amount left to populate:", pending.length);

        for (uint256 offset = 0; offset < pending.length; offset += _assetsPerCall) {
            uint256 batchLength = pending.length - offset < _assetsPerCall ? pending.length - offset : _assetsPerCall;
            bytes32[] memory batch = new bytes32[](batchLength);
            for (uint256 i = 0; i < batchLength; ++i) {
                batch[i] = _assetIds[pending[offset + i]];
            }

            uint256[] memory populatedAmounts = _ntv.populateBridgedOut(_chainId, batch);
            for (uint256 i = 0; i < batchLength; ++i) {
                _populatedPerAsset[pending[offset + i]] += populatedAmounts[i];
            }
        }
    }

    /// @notice Indexes into `_assetIds` of the assets that still hold a non-zero legacy amount for
    /// `_chainId`.
    /// @dev Pairs whose legacy amount is zero are dropped: populating them would only burn gas on writing
    ///      the "already populated" flag, since a later call would add zero anyway.
    function _pendingAssetIndexes(
        IL1NativeTokenVault _ntv,
        uint256 _chainId,
        bytes32[] memory _assetIds
    ) private view returns (uint256[] memory pending) {
        uint256[] memory buffer = new uint256[](_assetIds.length);
        uint256 count;

        for (uint256 i = 0; i < _assetIds.length; ++i) {
            bytes32 assetId = _assetIds[i];
            if (_ntv.bridgedOutPopulated(_chainId, assetId)) {
                continue;
            }
            if (_ntv.legacyBridgedOutForChain(_chainId, assetId) == 0) {
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

    /// @notice Cross-checks the per-chain legacy amounts against L1's own bulkhead in the legacy tracker.
    /// @dev The tracker keeps L1's bulkhead as `MAX_TOKEN_BALANCE` minus everything ever bridged out of L1,
    ///      so its complement must equal the sum of the per-chain amounts. A mismatch means the assumptions
    ///      about the legacy state do not hold and the amounts must be reviewed by hand; set
    ///      `BRIDGED_OUT_SKIP_INVARIANT_CHECK=true` to populate anyway. Skipped for assets that the tracker
    ///      never registered (their legacy amounts live in the vault's own deprecated mapping instead) and
    ///      for ecosystems that never had a tracker.
    function _checkLegacyTotalsInvariant(
        IL1NativeTokenVault _ntv,
        uint256[] memory _chainIds,
        bytes32[] memory _assetIds,
        bool _skipCheck
    ) private view {
        address legacyTracker = _ntv.legacyL1AssetTracker();
        if (legacyTracker == address(0)) {
            console.log("No legacy asset tracker recorded, skipping the legacy totals cross-check");
            return;
        }

        for (uint256 i = 0; i < _assetIds.length; ++i) {
            bytes32 assetId = _assetIds[i];
            if (!ILegacyL1AssetTracker(legacyTracker).isAssetRegistered(assetId)) {
                continue;
            }

            uint256 perChainSum;
            for (uint256 j = 0; j < _chainIds.length; ++j) {
                perChainSum += _ntv.legacyBridgedOutForChain(_chainIds[j], assetId);
            }
            uint256 trackedOutflow = MAX_TOKEN_BALANCE -
                ILegacyL1AssetTracker(legacyTracker).chainBalance(block.chainid, assetId);

            if (perChainSum != trackedOutflow) {
                console.log("  Legacy totals mismatch for asset:");
                console.logBytes32(assetId);
                console.log("    sum over chains:", perChainSum);
                console.log("    outflow recorded for L1:", trackedOutflow);
                require(_skipCheck, "bridgedOut: legacy per-chain amounts do not match L1's recorded outflow");
            }
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

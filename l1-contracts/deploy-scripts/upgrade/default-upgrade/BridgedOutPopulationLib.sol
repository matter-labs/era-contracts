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
    /// legacy amount.
    /// @param _bridgehub The L1 bridgehub, used to discover the NTV and the registered chains.
    /// @return totalPopulated The total amount folded into `bridgedOut` across all chains.
    function populateBridgedOutForAllChains(address _bridgehub) internal returns (uint256 totalPopulated) {
        IL1NativeTokenVault ntv = _nativeTokenVault(_bridgehub);
        uint256[] memory chainIds = IBridgehubBase(_bridgehub).getAllZKChainChainIDs();
        bytes32[] memory assetIds = _l1NativeAssetIds(ntv);

        console.log("Populating bridgedOut. Chains:", chainIds.length);
        console.log("L1-native assets found in the NTV:", assetIds.length);
        console.log("Legacy L1 asset tracker:", ntv.legacyL1AssetTracker());

        _checkLegacyTotalsInvariant(ntv, chainIds, assetIds);

        uint256 assetsPerCall = vm.envOr("BRIDGED_OUT_ASSETS_PER_CALL", DEFAULT_ASSETS_PER_CALL);
        require(assetsPerCall != 0, "BRIDGED_OUT_ASSETS_PER_CALL must be non-zero");

        for (uint256 i = 0; i < chainIds.length; ++i) {
            totalPopulated += _populateBridgedOutForChain(ntv, chainIds[i], assetIds, assetsPerCall);
        }

        console.log("bridgedOut population complete. Total amount populated:", totalPopulated);
    }

    /// @notice Populates `bridgedOut` for a single chain, batching the assets across several calls.
    /// @param _ntv The L1 native token vault.
    /// @param _chainId The chain whose legacy amounts are folded in.
    /// @param _assetIds The L1-native assets to consider.
    /// @param _assetsPerCall Maximum number of assets per `populateBridgedOut` call.
    /// @return populated The amount folded into `bridgedOut` for this chain.
    function _populateBridgedOutForChain(
        IL1NativeTokenVault _ntv,
        uint256 _chainId,
        bytes32[] memory _assetIds,
        uint256 _assetsPerCall
    ) private returns (uint256 populated) {
        bytes32[] memory pending = _pendingAssetIds(_ntv, _chainId, _assetIds);
        if (pending.length == 0) {
            return 0;
        }

        console.log("  Chain:", _chainId);
        console.log("  Assets with a legacy amount left to populate:", pending.length);

        for (uint256 offset = 0; offset < pending.length; offset += _assetsPerCall) {
            uint256 batchLength = pending.length - offset < _assetsPerCall ? pending.length - offset : _assetsPerCall;
            bytes32[] memory batch = new bytes32[](batchLength);
            for (uint256 i = 0; i < batchLength; ++i) {
                batch[i] = pending[offset + i];
            }
            populated += _ntv.populateBridgedOut(_chainId, batch);
        }

        console.log("  Populated amount for the chain:", populated);
    }

    /// @notice The L1-native assets of `_chainId` that still hold a non-zero legacy amount.
    /// @dev Pairs whose legacy amount is zero are dropped: populating them would only burn gas on writing
    ///      the "already populated" flag, since a later call would add zero anyway.
    function _pendingAssetIds(
        IL1NativeTokenVault _ntv,
        uint256 _chainId,
        bytes32[] memory _assetIds
    ) private view returns (bytes32[] memory pending) {
        bytes32[] memory buffer = new bytes32[](_assetIds.length);
        uint256 count;

        for (uint256 i = 0; i < _assetIds.length; ++i) {
            bytes32 assetId = _assetIds[i];
            if (_ntv.bridgedOutPopulated(_chainId, assetId)) {
                continue;
            }
            if (_ntv.legacyBridgedOutForChain(_chainId, assetId) == 0) {
                continue;
            }
            buffer[count] = assetId;
            ++count;
        }

        pending = new bytes32[](count);
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

    /// @notice Cross-checks the per-chain legacy amounts against L1's own entry in the legacy tracker.
    /// @dev The tracker keeps L1's entry as `MAX_TOKEN_BALANCE` minus everything ever bridged out of L1, so
    ///      its complement must equal the sum of the per-chain amounts. A mismatch means the assumptions
    ///      about the legacy state do not hold and the amounts must be reviewed by hand; set
    ///      `BRIDGED_OUT_SKIP_INVARIANT_CHECK=true` to populate anyway. Skipped for assets that the tracker
    ///      never registered (their legacy amounts live in the vault's own deprecated mapping instead) and
    ///      for ecosystems that never had a tracker.
    function _checkLegacyTotalsInvariant(
        IL1NativeTokenVault _ntv,
        uint256[] memory _chainIds,
        bytes32[] memory _assetIds
    ) private view {
        address legacyTracker = _ntv.legacyL1AssetTracker();
        if (legacyTracker == address(0)) {
            console.log("No legacy asset tracker recorded, skipping the legacy totals cross-check");
            return;
        }
        bool skipCheck = vm.envOr("BRIDGED_OUT_SKIP_INVARIANT_CHECK", false);

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
                require(skipCheck, "bridgedOut: legacy per-chain amounts do not match L1's recorded outflow");
            }
        }
    }

    function _nativeTokenVault(address _bridgehub) private view returns (IL1NativeTokenVault) {
        return
            IL1NativeTokenVault(
                address(IL1AssetRouter(address(IBridgehubBase(_bridgehub).assetRouter())).nativeTokenVault())
            );
    }
}

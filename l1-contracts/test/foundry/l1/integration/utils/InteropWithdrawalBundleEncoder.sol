// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L2_ASSET_ROUTER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";
import {IAssetRouterShared} from "contracts/bridge/asset-router/IAssetRouterShared.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {
    BUNDLE_IDENTIFIER,
    BundleAttributes,
    INTEROP_BUNDLE_VERSION,
    INTEROP_CALL_VERSION,
    InteropBundle,
    InteropCall
} from "contracts/common/Messaging.sol";

/// @title InteropWithdrawalBundleEncoder
/// @notice Test-only helper that reconstructs the single-call L2->L1 withdrawal `InteropBundle` the L2
/// InteropCenter emits, for finalizing withdrawals via `L1InteropHandler.executeBundle` under a mocked
/// inclusion proof. Production flows never reconstruct bundles — they pass the actual emitted bundle bytes.
library InteropWithdrawalBundleEncoder {
    /// @notice Builds the `BUNDLE_IDENTIFIER`-prefixed L2->L1 withdrawal message form.
    /// @param _chainId The source ZK chain ID (encoded both in the bundle and the inner call).
    /// @param _l1AssetRouter The L1 asset router that the bundle's single call targets.
    /// @param _assetId The asset being withdrawn.
    /// @param _transferData The bridge-mint/transfer data for the asset.
    /// @param _interopBundleSalt The bundle salt; see {encodeInteropWithdrawalBundle}.
    function encodeInteropWithdrawalBundleMessage(
        uint256 _chainId,
        address _l1AssetRouter,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _interopBundleSalt
    ) internal view returns (bytes memory) {
        return
            abi.encodePacked(
                BUNDLE_IDENTIFIER,
                encodeInteropWithdrawalBundle(_chainId, _l1AssetRouter, _assetId, _transferData, _interopBundleSalt)
            );
    }

    /// @notice Builds the ABI-encoded single-call `InteropBundle` for an interop-routed withdrawal, without the
    /// `BUNDLE_IDENTIFIER` prefix. This is the form consumed by `IInteropHandler.executeBundle`.
    /// @dev The `destinationBaseTokenAssetId` matches what the L2 InteropCenter sets for an L1-destined bundle
    /// (L1's ETH asset ID), which `InteropHandlerBase._validateBundleDestinationContext` checks on execution.
    /// @param _chainId The source ZK chain ID (encoded both in the bundle and the inner call).
    /// @param _l1AssetRouter The L1 asset router that the bundle's single call targets.
    /// @param _assetId The asset being withdrawn.
    /// @param _transferData The bridge-mint/transfer data for the asset.
    /// @param _interopBundleSalt The bundle salt. Real bundles carry the salt assigned by the L2 InteropCenter
    /// (`keccak256(abi.encodePacked(sender, userSalt))`, where `userSalt` comes from the `interopBundleSalt`
    /// bundle attribute) — a reconstruction can only be finalized against a real inclusion proof if it supplies
    /// that same salt, since the bundle bytes must hash-match the emitted message. Tests running under mocked
    /// proofs must still pass a salt unique per bundle, because the salt is what keeps distinct-but-identical
    /// withdrawals from colliding into the same bundle hash (and thus reverting with `BundleAlreadyProcessed`).
    function encodeInteropWithdrawalBundle(
        uint256 _chainId,
        address _l1AssetRouter,
        bytes32 _assetId,
        bytes memory _transferData,
        bytes32 _interopBundleSalt
    ) internal view returns (bytes memory) {
        InteropCall[] memory calls = new InteropCall[](1);
        calls[0] = InteropCall({
            version: INTEROP_CALL_VERSION,
            shadowAccount: false,
            to: _l1AssetRouter,
            from: L2_ASSET_ROUTER_ADDR,
            value: 0,
            data: abi.encodeCall(IAssetRouterShared.finalizeDeposit, (_chainId, _assetId, _transferData))
        });
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: _chainId,
            destinationChainId: block.chainid,
            destinationBaseTokenAssetId: DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS),
            interopBundleSalt: _interopBundleSalt,
            calls: calls,
            // The attribute-level salt is a placeholder: the reconstruction's uniqueness comes from
            // `interopBundleSalt` above.
            bundleAttributes: BundleAttributes({
                executionAddress: hex"",
                unbundlerAddress: hex"",
                useFixedFee: false,
                salt: bytes32(0)
            })
        });
        return abi.encode(bundle);
    }
}

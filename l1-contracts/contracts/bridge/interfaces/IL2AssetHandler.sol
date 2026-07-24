// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

/// @title L2 asset handler recovery interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The L2 counterpart of {IL1AssetHandler}: the recovery surface an L2 asset handler exposes
/// so that burns it performed on the atomic-interop send path can be reversed on timeout (see
/// {L2AssetRouter.recoverAtomicCall}). The native token vault implements it (see
/// {INativeTokenVaultBase}); a custom asset handler that wants its burns to be recoverable on the
/// atomic timeout path MUST implement it as well — otherwise the recovery call (and with it the whole
/// refund claim for the bundle) reverts.
interface IL2AssetHandler {
    /// @notice Returns a failed/expired atomic-interop transfer's funds to the depositor, reversing
    /// the `bridgeBurn` performed at send time.
    /// @dev Callable only by the asset router, which gates it on a proven IMT non-inclusion (timeout).
    /// @param _chainId The chain the asset was being bridged to at burn time.
    /// @param _assetId The asset being recovered.
    /// @param _data The bridge-mint data produced by the handler's own `bridgeBurn`; the handler
    /// refunds the data's original depositor.
    function bridgeRecoverFailedTransfer(uint256 _chainId, bytes32 _assetId, bytes calldata _data) external payable;
}

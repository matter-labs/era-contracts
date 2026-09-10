// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

/// @title Legacy L1 asset tracker interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Read-only view of the V31 `L1AssetTracker`, which held the per-chain bulkhead accounting
/// before it was replaced by `L1NativeTokenVault.bridgedOut`.
/// @dev The contract itself was removed from this repository together with the rest of the asset
/// trackers, but the already-deployed instance keeps its storage. `L1NativeTokenVault` reads it
/// during the one-off `bridgedOut` population (see {L1NativeTokenVault-populateBridgedOut});
/// nothing writes to it anymore once the new implementations are live.
interface ILegacyL1AssetTracker {
    /// @notice Bulkhead amount of `_assetId` that the V31 accounting attributed to `_chainId`.
    /// @dev For a chain other than the asset's origin chain this is the net amount bridged to that
    /// chain (or to its settlement layer). The origin chain's own bulkhead starts at
    /// `MAX_TOKEN_BALANCE` — the "infinite deposit at inception" convention — rather than at a real
    /// balance, so it must never be summed.
    function chainBalance(uint256 _chainId, bytes32 _assetId) external view returns (uint256);

    /// @notice Whether the asset was ever registered in the legacy tracker.
    /// @dev Unregistered assets have a zero bulkhead everywhere, including their origin chain.
    function isAssetRegistered(bytes32 _assetId) external view returns (bool);
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The part of the claim distributor of a shut down chain that the L1AssetTracker and the
/// ShutdownDistributorInstaller rely on.
/// @dev Implemented by the ZKsync Lite sunset distributor (`ZkSyncLiteSunsetClaimDistributorL1`), which is used as is.
interface IShutdownClaimDistributor {
    /// @notice Initializes the distributor behind a proxy.
    /// @param _merkleRoot The root of the Merkle tree of the claims.
    /// @param _windowStart The timestamp from which claims are accepted.
    /// @param _initialOwner The owner of the distributor, who can pause it.
    function initialize(bytes32 _merkleRoot, uint256 _windowStart, address _initialOwner) external;

    /// @notice The root of the Merkle tree of the claims. Zero until the distributor is initialized.
    function MERKLE_ROOT() external view returns (bytes32);
}

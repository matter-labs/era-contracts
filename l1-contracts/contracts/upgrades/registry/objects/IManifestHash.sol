// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

/// @notice Commitment to the complete manifest pinned by a registry object.
interface IManifestHash {
    /// @notice `keccak256(abi.encode(manifest))`, the commitment governance reviews.
    function manifestHash() external view returns (bytes32);
}

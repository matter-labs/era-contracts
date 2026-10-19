// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IManifestHash} from "./IManifestHash.sol";

/// @notice Stores a registry object's ABI-encoded manifest at construction.
abstract contract ManifestStorage is IManifestHash {
    // Encoding avoids field-by-field copies of nested struct arrays into storage, which the
    // legacy codegen pipeline does not support. Concrete objects retain their typed decoders.
    bytes internal encodedManifest;

    constructor(bytes memory _encodedManifest) {
        encodedManifest = _encodedManifest;
    }

    /// @inheritdoc IManifestHash
    function manifestHash() external view returns (bytes32) {
        return keccak256(encodedManifest);
    }
}

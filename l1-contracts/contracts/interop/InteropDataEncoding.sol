// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for interop data encoding and decoding to reduce possibility of errors.
 */
library InteropDataEncoding {
    /// @notice Canonical hash of an ABI-encoded {InteropBundle}. The bundle already commits its own
    /// `sourceChainId` field, so it is not mixed in separately — source and destination derive the same
    /// hash from the same bundle bytes.
    function encodeInteropBundleHash(bytes memory _bundle) internal pure returns (bytes32) {
        return keccak256(_bundle);
    }
}

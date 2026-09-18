// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Helper library for interop data encoding and decoding to reduce possibility of errors.
 */
library InteropDataEncoding {
    function encodeInteropBundleHash(uint256 _sourceChainId, bytes memory _bundle) internal pure returns (bytes32) {
        return keccak256(abi.encode(_sourceChainId, _bundle));
    }
}

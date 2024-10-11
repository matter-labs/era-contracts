// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ISafe {
    function getMessageHash(bytes memory _message) external view returns (bytes32);
}

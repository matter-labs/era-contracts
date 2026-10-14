// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ISafe {
    function getMessageHash(bytes memory _message) external view returns (bytes32);

    function getOwners() external view returns (address[] memory);

    function getThreshold() external view returns (uint256);

    function approveHash(bytes32 _hashToApprove) external;
}

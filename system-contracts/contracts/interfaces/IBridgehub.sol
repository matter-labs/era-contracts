// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IBridgehub {
    function setAddresses(address _assetRouter, address _stmDeployer, address _messageRoot) external;

    function owner() external view returns (address);
}

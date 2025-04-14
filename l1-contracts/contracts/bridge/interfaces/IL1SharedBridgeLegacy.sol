// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1SharedBridgeLegacy {
    function l2BridgeAddress(uint256 _chainId) external view returns (address);
}

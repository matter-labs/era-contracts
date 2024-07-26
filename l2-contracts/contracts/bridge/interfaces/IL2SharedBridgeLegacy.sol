// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
interface IL2SharedBridgeLegacy {
    function l1TokenAddress(address _l2Token) external view returns (address);

    function l2TokenAddress(address _l1Token) external view returns (address);
}

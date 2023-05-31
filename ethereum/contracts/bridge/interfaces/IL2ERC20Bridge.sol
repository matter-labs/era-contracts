// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

/// @author Matter Labs
interface IL2ERC20Bridge {
    function initialize(
        address _l1Bridge,
        bytes32 _l2TokenProxyBytecodeHash,
        address _governor
    ) external;
}

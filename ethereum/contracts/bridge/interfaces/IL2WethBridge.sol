// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IL2WethBridge {
    function initialize(address _l1Bridge, address _l1WethAddress, address _l2WethAddress) external;
}

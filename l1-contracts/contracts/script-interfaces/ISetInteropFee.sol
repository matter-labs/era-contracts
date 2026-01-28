// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

interface ISetInteropFee {
    function setInteropFee(address chainAdmin, address target, uint256 fee) external;
}

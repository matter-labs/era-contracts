// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

interface IComplexUpgrader {
    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}

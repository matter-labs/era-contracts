// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IComplexUpgrader {
    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}

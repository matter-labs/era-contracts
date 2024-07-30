// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IComplexUpgrader {
    function upgrade(address _delegateTo, bytes calldata _calldata) external payable;
}

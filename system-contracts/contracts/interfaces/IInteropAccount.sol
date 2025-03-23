// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

interface IInteropAccount {
    function forwardFromIC(address _to, uint256 _value, bytes memory _data) external payable;
}

// SPDX-License-Identifier: UNLICENSED
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

interface ISystemContext {
    function setChainId(uint256 _newChainId) external;
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.0;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ISystemContext {
    function setChainId(uint256 _newChainId) external;
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IOwnable {
    function owner() external view returns (address);
    function transferOwnership(address newOwner) external;
    function pendingOwner() external view returns (address);
    function acceptOwnership() external;
}

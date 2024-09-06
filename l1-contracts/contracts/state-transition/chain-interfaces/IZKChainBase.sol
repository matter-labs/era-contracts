// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title The interface of the ZKsync contract, responsible for the main ZKsync logic.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IZKChainBase {
    /// @return Returns facet name.
    function getName() external view returns (string memory);
}

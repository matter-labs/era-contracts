// SPDX-License-Identifier: UNLICENSED
// We use a floating point pragma here so it can be used within other projects that interact with the zkSync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title The interface of the zkSync contract, responsible for the main zkSync logic.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IZkSyncHyperchainBase {
    /// @return Returns facet name.
    function getName() external view returns (string memory);
}

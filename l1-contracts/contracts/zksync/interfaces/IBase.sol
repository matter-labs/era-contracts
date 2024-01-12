// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.20;

/// @title The interface of the zkSync contract, responsible for the main zkSync logic.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IBase {
    /// @return Returns facet name.
    function getName() external view returns (string memory);
}

// SPDX-License-Identifier: UNLICENSED
pragma solidity 0.8.24;

/// @title The interface of the ZKSync contract, responsible for the main ZKSync logic.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IZkSyncHyperchainBase {
    /// @return Returns facet name.
    function getName() external view returns (string memory);
}

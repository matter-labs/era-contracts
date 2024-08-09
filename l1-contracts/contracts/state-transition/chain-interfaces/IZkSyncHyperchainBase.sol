// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/// @title The interface of the ZKsync contract, responsible for the main ZKsync logic.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IZkSyncHyperchainBase {
    /// @return Returns facet name.
    function getName() external view returns (string memory);
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";

/// @title ICoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The ecosystem domain's executor: applies Core-domain proxy upgrade transitions through the
///         ecosystem `ProxyAdmin` it owns. See {protocol-docs/ecosystem-upgrade-coordination.md}.
interface ICoreUpgradeExecutor {
    /// @notice Emitted after a Core-domain transition's rows were applied through the bound admin.
    event L1UpgradeApplied(address indexed coreTransition);

    /// @notice Applies a Core-domain transition's source-checked implementation swaps through the
    ///         bound `ProxyAdmin`, and verifies every row at its `implNew` before returning.
    /// @param _coreTransition The write-once transition approved by governance; its domain must be
    ///        `Core`.
    function applyL1Upgrade(IProxyUpgradeTransition _coreTransition) external;
}

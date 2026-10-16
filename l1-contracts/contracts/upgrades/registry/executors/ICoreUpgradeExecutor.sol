// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ICoreTransition} from "../objects/ICoreTransition.sol";
import {IDomainUpgradeExecutor} from "./IDomainUpgradeExecutor.sol";

/// @title ICoreUpgradeExecutor
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The ecosystem domain's executor: the coordinator surface ({IDomainUpgradeExecutor}) plus
///         applying a core transition through the ecosystem `ProxyAdmin` it owns. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface ICoreUpgradeExecutor is IDomainUpgradeExecutor {
    /// @notice Emitted after a core transition's rows were applied through the bound admin.
    event L1UpgradeApplied(address indexed coreTransition);

    /// @notice Applies a core transition's source-checked implementation swaps through the bound
    ///         `ProxyAdmin`, and verifies every row at its `implNew` before returning. The owner's
    ///         route outside an operation (the bootstrap edge and recovery); inside one, the
    ///         coordinator applies the manifest's core transition through `applyOperation`.
    /// @param _coreTransition The write-once core transition approved by governance.
    function applyL1Upgrade(ICoreTransition _coreTransition) external;
}

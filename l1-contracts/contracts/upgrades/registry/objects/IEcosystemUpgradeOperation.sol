// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {OperationManifest, ProxyUpgradeRow} from "../RegistryTypes.sol";

/// @title IEcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Immutable description of one ecosystem upgrade: its three optional changes and the
///         delay before governance may execute them. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface IEcosystemUpgradeOperation {
    /// @notice `keccak256(abi.encode(manifest))` — the commitment governance reviews.
    function manifestHash() external view returns (bytes32);

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() external view returns (OperationManifest memory);

    /// @notice The ecosystem leg's `CoreTransition`, zero when the operation has none.
    function coreTransition() external view returns (address);

    /// @notice The PARTICIPATING CTM-domain rows, flattened from the enum-indexed inventory (the
    ///         slots explicitly marked "not upgraded" are dropped). Empty when the operation
    ///         changes no CTM-domain implementation.
    function ctmInfrastructureRows() external view returns (ProxyUpgradeRow[] memory);

    /// @notice The transition applied to the coordinator's bound CTM, zero when the operation
    ///         moves no chain version.
    function transition() external view returns (address);

    /// @notice The `GovernanceUpgradeTimer` gating stage 1. Never zero.
    function timer() external view returns (address);

    /// @notice Reverts unless the timer and every participating infrastructure row's
    ///         implementation is deployed code.
    /// @dev It does NOT attest that the code is the reviewed code — that is governance's approval
    ///      of this object's member ADDRESSES, established off-chain before approval (see
    ///      {docs/registry-driven-upgrades.md}).
    function validate() external view;
}

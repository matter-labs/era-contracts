// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IManifestHash} from "./IManifestHash.sol";
import {OperationManifest, ProxyUpgradeRow} from "../RegistryTypes.sol";

/// @title IEcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Immutable description of one ecosystem upgrade: its three optional changes. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev The coordinator is its only reader: it reads `getManifest()` once, held to
///      `manifestHash()`; the per-field getters are for tooling and never steer an execution.
interface IEcosystemUpgradeOperation is IManifestHash {
    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() external view returns (OperationManifest memory);

    /// @notice The ecosystem leg's `CoreTransition`, zero when the operation has none.
    function coreTransition() external view returns (address);

    /// @notice The PARTICIPATING CTM-domain rows, flattened from the enum-indexed inventory (the
    ///         slots explicitly marked "not upgraded" are dropped). Empty when the operation
    ///         changes no CTM-domain implementation.
    function ctmInfrastructureRows() external view returns (ProxyUpgradeRow[] memory);

    /// @notice The `CTMTransition` applied to the coordinator's bound CTM, zero when the operation
    ///         moves no chain version.
    function ctmTransition() external view returns (address);

    /// @notice Reverts unless every participating infrastructure row's implementation is deployed
    ///         code, and the core transition and CTM transition it names (when it names them) are
    ///         deployed and pass their own `validate()` — the whole operation validated in one call.
    /// @dev It does NOT attest that the code is the reviewed code — that is governance's approval
    ///      of this object's member ADDRESSES, established off-chain before approval (see
    ///      {docs/registry-driven-upgrades.md}).
    function validate() external view;
}

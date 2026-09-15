// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {OperationManifest} from "../RegistryTypes.sol";

/// @title IEcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Immutable description of one ecosystem upgrade: the optional ecosystem leg and the
///         CTM transition the coordinator applies. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface IEcosystemUpgradeOperation {
    /// @notice `keccak256(abi.encode(manifest))` — the commitment governance reviews.
    function manifestHash() external view returns (bytes32);

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() external view returns (OperationManifest memory);

    /// @notice The ecosystem leg's `CoreRegistry`, zero when the operation has none.
    function coreRegistry() external view returns (address);

    /// @notice The transition applied to the coordinator's bound CTM.
    function transition() external view returns (address);
}

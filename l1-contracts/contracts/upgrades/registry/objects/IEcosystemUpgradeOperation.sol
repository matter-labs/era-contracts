// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMLeg, OperationManifest} from "../RegistryTypes.sol";

/// @title IEcosystemUpgradeOperation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Immutable description of one ecosystem upgrade: the optional ecosystem leg and the
///         ordered CTM legs the coordinator drives together. See
///         {protocol-docs/ecosystem-upgrade-coordination.md}.
interface IEcosystemUpgradeOperation {
    /// @notice `keccak256(abi.encode(manifest))` — the commitment governance reviews.
    function manifestHash() external view returns (bytes32);

    /// @notice The whole manifest, exactly as it was pinned.
    function getManifest() external view returns (OperationManifest memory);

    /// @notice The ecosystem leg's `CoreRegistry`, zero when the operation has none.
    function coreRegistry() external view returns (address);

    /// @notice The CTM legs in stage-1 application order.
    function legs() external view returns (CTMLeg[] memory);
}

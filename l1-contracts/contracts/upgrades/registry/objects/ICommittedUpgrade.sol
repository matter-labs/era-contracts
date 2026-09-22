// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2UpgradePlan} from "../RegistryTypes.sol";

/// @notice The read surface a per-chain upgrade engine uses on the write-once object the committed
///         cut names — a `CTMTransition` for an ordinary edge, the one-time
///         `RegistryBootstrapMigration` for the bootstrap. See {docs/registry-driven-upgrades.md}.
/// @dev The two objects carry different manifests, so what they share is this view rather than a
///      manifest type. It exists so an engine takes the whole edge from ONE object instead of
///      being handed its parts separately.
interface ICommittedUpgrade {
    /// @notice The edge this object commits, in one read: the version the chain lands on, the
    ///         earliest time it may execute (zero means no gate) and the release whose facet set
    ///         and verifier it installs.
    function upgradeTarget()
        external
        view
        returns (uint256 newProtocolVersion, uint256 upgradeTimestamp, address newRelease);

    /// @notice The FINAL, executable L2 plan of the edge.
    function l2Plan() external view returns (L2UpgradePlan memory);
}

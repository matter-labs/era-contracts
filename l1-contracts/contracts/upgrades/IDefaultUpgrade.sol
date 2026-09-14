// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2CanonicalTransaction} from "../common/Messaging.sol";

/// @notice The per-chain engine of a registry-driven upgrade: the init target of the cut a chain
///         reads from its CTM for a committed `CTMTransition`.
interface IDefaultUpgrade {
    /// @notice Executes one committed transition on the diamond this contract is delegatecalled
    ///         into. The transition is the sole input: its derived facet cuts, its version edge and
    ///         schedule, the verifier of its TARGET release and the L2 protocol upgrade transaction
    ///         composed from its L2 plan.
    /// @param _transition The `CTMTransition` the chain's CTM committed for this edge.
    /// @return The diamond-init success value.
    function upgradeFromTransition(address _transition) external returns (bytes32);

    /// @notice The L2 protocol upgrade transaction `upgradeFromTransition` commits for `_transition`
    ///         BEFORE any per-chain substitution, composed for the ecosystem of `_bridgehub`.
    /// @dev For off-chain consumers; free of diamond-storage reads so it can be called directly on
    ///      this contract rather than through a chain.
    /// @param _transition The `CTMTransition` to compose for.
    /// @param _bridgehub The Bridgehub of the ecosystem the chain belongs to.
    function l2UpgradeTx(address _transition, address _bridgehub) external view returns (L2CanonicalTransaction memory);
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2CanonicalTransaction} from "../common/Messaging.sol";

/// @notice The per-chain engine of a registry-driven upgrade: the init target of the cut a chain
///         reads from its CTM for a committed `CTMTransition`.
interface IDefaultUpgrade {
    /// @notice Executes one committed transition on the diamond this contract is delegatecalled
    ///         into. The transition is the sole input: its derived facet cuts, its version edge and
    ///         schedule, the verifier of its TARGET release and the L2 protocol upgrade transaction
    ///         composed from its L2 plan for this chain.
    /// @param _transition The `CTMTransition` the chain's CTM committed for this edge.
    /// @return The diamond-init success value.
    function upgradeFromTransition(address _transition) external returns (bytes32);

    /// @notice The L2 protocol upgrade transaction `upgradeFromTransition` commits on chain
    ///         `_chainId` of the ecosystem of `_bridgehub` for `_transition` — the FINAL transaction,
    ///         exactly as the chain stores its hash.
    /// @dev THE composition view: free of diamond-storage reads, so it is called directly on this
    ///      contract (or through `ICTMTransition.l2UpgradeTx`) rather than through a chain.
    /// @param _transition The `CTMTransition` to compose for.
    /// @param _bridgehub The Bridgehub of the ecosystem the chain belongs to.
    /// @param _chainId The chain to compose for.
    function l2UpgradeTx(
        address _transition,
        address _bridgehub,
        uint256 _chainId
    ) external view returns (L2CanonicalTransaction memory);
}

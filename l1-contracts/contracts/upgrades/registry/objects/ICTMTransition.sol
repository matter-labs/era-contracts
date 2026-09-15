// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICommittedUpgrade} from "./ICommittedUpgrade.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {ProxyUpgradeRow, TransitionManifest} from "../RegistryTypes.sol";

/// @notice Immutable description of how one CTM release becomes another.
/// @dev The facet cuts and table-derived L2 deployments are NOT authored: they are DERIVED from
///      the `(fromRelease, newRelease)` pair at initialization and stored. What governance reviews
///      is two releases and this transition's schedule/engine/L2 plan; the delta is a
///      pure function of the release pair, so transition and release state cannot diverge.
interface ICTMTransition is ICommittedUpgrade {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every pinned value:
    ///         the single value governance reviews against the audited manifest.
    function manifestHash() external view returns (bytes32);

    /// @notice The whole manifest, exactly as it was pinned. Readers needing several fields
    ///         should take this once instead of calling the per-field getters (each getter
    ///         decodes the full manifest).
    function getManifest() external view returns (TransitionManifest memory);

    function oldProtocolVersion() external view returns (uint256);

    function newProtocolVersion() external view returns (uint256);

    /// @notice The release this transition departs from. Never zero — bootstrapping a pre-registry
    ///         CTM is one-time migration code, not a permanent special case.
    function fromRelease() external view returns (address);

    function newRelease() external view returns (address);

    /// @notice The codehash-pinned upgrade-execution contract the committed cut delegatecalls
    ///         (`upgradeFromTransition`). Transition-scoped machinery — explicit and pinned.
    function upgradeEngine() external view returns (address);

    function oldProtocolVersionDeadline() external view returns (uint256);

    function upgradeTimestamp() external view returns (uint256);

    /// @notice The `GovernanceUpgradeTimer` gating stage 1 of this transition.
    function upgradeTimer() external view returns (address);

    /// @notice The DERIVED facet swaps realizing `fromRelease -> newRelease` routing.
    /// @notice The final, ready-to-execute diamond cuts — DERIVED from the release pair at
    ///         initialization (all `Remove` cuts first, then `Add`), applied verbatim by the
    ///         chain with no re-diffing.
    function facetCuts() external view returns (Diamond.FacetCut[] memory);

    /// @notice CTM-domain implementation swaps applied by the bound executor before the commit.
    function ctmProxyRows() external view returns (ProxyUpgradeRow[] memory);

    /// @notice The L2 protocol upgrade transaction this transition's engine commits on chain
    ///         `_chainId` of the ecosystem of `_bridgehub` — the single read entry point for tooling.
    /// @dev Forwards to the pinned engine's `IDefaultUpgrade.l2UpgradeTx`: the composition code
    ///      lives in the per-upgrade pinned engine, never here, because the transition's own code
    ///      (`TRANSITION_CODEHASH`) is frozen for the executor's lifetime while the engine ships per
    ///      release.
    /// @param _bridgehub The Bridgehub of the ecosystem the chain belongs to.
    /// @param _chainId The chain to compose for.
    function l2UpgradeTx(address _bridgehub, uint256 _chainId) external view returns (L2CanonicalTransaction memory);

    /// @notice Reverts unless BOTH releases validate and every codehash this transition pins
    ///         (engine, timer, composer, ecosystem leg, CTM-domain rows) matches the live code.
    ///         THE enforcement surface: the paths that commit or apply a transition call it.
    function validate() external view;

    /// @notice Whether {validate} would pass — the same pins, read without reverting, for
    ///         inspection and deployment tooling. Never an enforcement surface.
    function verifyAll() external view returns (bool);
}

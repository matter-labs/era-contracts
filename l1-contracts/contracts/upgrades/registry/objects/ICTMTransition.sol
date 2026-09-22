// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICommittedUpgrade} from "./ICommittedUpgrade.sol";
import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {L2CanonicalTransaction} from "../../../common/Messaging.sol";
import {TransitionManifest, ReleaseDiff} from "../RegistryTypes.sol";

/// @notice Immutable description of how one CTM release becomes another: what chains upgrade
///         from and to, and by when. Infrastructure changes and the execution delay belong to the
///         OPERATION that carries this transition, not here.
/// @dev The facet cuts and table-derived L2 deployments are NOT authored: they are DERIVED from
///      the `(fromRelease, newRelease)` pair at initialization and stored. What governance reviews
///      is two releases and this transition's schedule/engine/L2 plan; the delta is a
///      pure function of the release pair, so transition and release state cannot diverge.
interface ICTMTransition is ICommittedUpgrade {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every manifest value:
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

    /// @notice The upgrade-execution contract the committed cut delegatecalls
    ///         (`upgradeFromTransition`). Transition-scoped machinery — named explicitly.
    function upgradeEngine() external view returns (address);

    function oldProtocolVersionDeadline() external view returns (uint256);

    function upgradeTimestamp() external view returns (uint256);

    /// @notice The DERIVED facet swaps realizing `fromRelease -> newRelease` routing.
    /// @notice The final, ready-to-execute diamond cuts — DERIVED from the release pair at
    ///         initialization (all `Remove` cuts first, then `Add`), applied verbatim by the
    ///         chain with no re-diffing.
    function facetCuts() external view returns (Diamond.FacetCut[] memory);

    /// @notice Which release members differ between `fromRelease` and `newRelease`, so a reviewer
    ///         learns what an edge actually changes without diffing two manifests. All-false for a
    ///         same-release (schedule-only) transition.
    function releaseDiff() external view returns (ReleaseDiff memory);

    /// @notice The L2 protocol upgrade transaction this transition's engine commits on chain
    ///         `_chainId` of the ecosystem of `_bridgehub` — the single read entry point for tooling.
    /// @dev Forwards to the engine's `IDefaultUpgrade.l2UpgradeTx`: the composition code lives in
    ///      the per-upgrade engine, never here, because the transition's own code
    ///      is frozen for the executor's lifetime while the engine ships per
    ///      release.
    /// @param _bridgehub The Bridgehub of the ecosystem the chain belongs to.
    /// @param _chainId The chain to compose for.
    function l2UpgradeTx(address _bridgehub, uint256 _chainId) external view returns (L2CanonicalTransaction memory);

    /// @notice Reverts unless BOTH releases validate and every contract this transition names
    ///         (engine, composer) is deployed code. THE enforcement surface: the paths that commit
    ///         or apply a transition call it.
    /// @dev It does NOT attest that the code is the reviewed code — that is governance's
    ///      approval of this object's member ADDRESSES, established off-chain before approval
    ///      (see {docs/registry-driven-upgrades.md}).
    function validate() external view;
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {Diamond} from "../../state-transition/libraries/Diamond.sol";

/// @notice The complete, typed L2 side of one transition: the force-deployments, the delegate
///         call the `L2ComplexUpgrader` performs after them, and the factory dependencies the
///         L1 -> L2 transaction carries. Shape-validated at transition initialization — a plan
///         that commits data the composed transaction would not execute refuses to exist.
/// @dev This is REVIEWED-AND-PINNED data, not proven state: L1 cannot verify L2 execution
///      effects, so the L1-side convergence guarantee deliberately does not extend here (see
///      the transition contract docs).
struct L2UpgradePlan {
    IComplexUpgrader.UniversalContractUpgradeInfo[] deployments;
    address delegateTo;
    bytes delegateCalldata;
    uint256[] factoryDepHashes;
}

/// @notice Immutable description of how one CTM release becomes another.
/// @dev The facet cuts and base-system hash CHANGES are NOT authored: they are DERIVED from the
///      `(fromRelease, newRelease)` pair at initialization and stored. What governance reviews
///      is two releases and this transition's schedule/engine/L2 plan; the delta is a
///      pure function of the release pair, so transition and release state cannot diverge.
interface ICTMTransition {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every pinned value,
    ///         and the key under which the deploying factory attests this instance.
    function manifestHash() external view returns (bytes32);

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

    /// @notice The DERIVED facet swaps realizing `fromRelease -> newRelease` routing.
    /// @notice The final, ready-to-execute diamond cuts — DERIVED from the release pair at
    ///         initialization (all `Remove` cuts first, then `Add`), applied verbatim by the
    ///         chain with no re-diffing.
    function facetCuts() external view returns (Diamond.FacetCut[] memory);

    /// @notice The DERIVED base-system hash changes (zero = carried over unchanged).
    function baseSystemContractHashChanges() external view returns (bytes32, bytes32, bytes32);

    function l2Plan() external view returns (L2UpgradePlan memory);

    /// @notice Reverts unless the transition, BOTH its releases, and all codehash pins are valid.
    function validate() external view;

    function verifyAll() external view returns (bool);
}

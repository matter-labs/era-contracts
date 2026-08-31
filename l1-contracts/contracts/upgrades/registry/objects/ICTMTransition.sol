// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../../../state-transition/libraries/Diamond.sol";
import {L2UpgradePlan, ProxyUpgradeRow, TransitionManifest} from "../RegistryTypes.sol";

/// @notice Immutable description of how one CTM release becomes another.
/// @dev The facet cuts and base-system hash CHANGES are NOT authored: they are DERIVED from the
///      `(fromRelease, newRelease)` pair at initialization and stored. What governance reviews
///      is two releases and this transition's schedule/engine/L2 plan; the delta is a
///      pure function of the release pair, so transition and release state cannot diverge.
interface ICTMTransition {
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

    /// @notice The DERIVED facet swaps realizing `fromRelease -> newRelease` routing.
    /// @notice The final, ready-to-execute diamond cuts — DERIVED from the release pair at
    ///         initialization (all `Remove` cuts first, then `Add`), applied verbatim by the
    ///         chain with no re-diffing.
    function facetCuts() external view returns (Diamond.FacetCut[] memory);

    /// @notice The DERIVED base-system hash changes (zero = carried over unchanged).
    function baseSystemContractHashChanges() external view returns (bytes32, bytes32, bytes32);

    /// @notice CTM-domain implementation swaps applied by the bound executor before the commit.
    function ctmProxyRows() external view returns (ProxyUpgradeRow[] memory);

    /// @notice The pinned `initData` of the row upgrading `_proxy` — served (through the
    ///         executor) to the new implementation's fixed `initializeUpgrade()`; see
    ///         {IUpgradeInit.sol}. Reverts when no row upgrades `_proxy`.
    function upgradeInitData(address _proxy) external view returns (bytes memory);

    function l2Plan() external view returns (L2UpgradePlan memory);

    /// @notice Reverts unless the transition, BOTH its releases, and all codehash pins are valid.
    function validate() external view;

    function verifyAll() external view returns (bool);
}

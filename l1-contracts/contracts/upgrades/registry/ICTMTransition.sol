// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IComplexUpgrader} from "../../state-transition/l2-deps/IComplexUpgrader.sol";
import {UpgradeFacetSwap} from "../../state-transition/libraries/ProposedUpgradeLib.sol";

/// @dev Only `info` is consumed on-chain ({CTMUpgradeComposer.buildL2UpgradeTx}); the previously
///      carried `key`/`bytecodeHash` were never read, so they are dropped.
struct L2Deployment {
    IComplexUpgrader.UniversalContractUpgradeInfo info;
}

/// @notice Immutable description of how one CTM release becomes another.
/// @dev Owns the version-schedule identity the release deliberately omits: it pins both the
///      release edge (`fromRelease -> newRelease`) and the version edge
///      (`oldProtocolVersion -> newProtocolVersion`), and carries the `verifier` for the new
///      version. "How A becomes B" therefore never identifies A through a version number alone.
interface ICTMTransition {
    function ctmProxy() external view returns (address);

    function oldProtocolVersion() external view returns (uint256);

    function newProtocolVersion() external view returns (uint256);

    function verifier() external view returns (address);

    /// @notice The release the CTM must currently be at for this transition to apply
    ///         (`address(0)` for a transition from a pre-registry version, e.g. v31 -> v32).
    function fromRelease() external view returns (address);

    /// @notice The release the CTM ends at. A patch transition sets this equal to `fromRelease`.
    function newRelease() external view returns (address);

    function defaultUpgrade() external view returns (address);

    function oldProtocolVersionDeadline() external view returns (uint256);

    function upgradeTimestamp() external view returns (uint256);

    function facetTransitions() external view returns (UpgradeFacetSwap[] memory);

    function l2Deployments() external view returns (L2Deployment[] memory);

    function l2UpgradeDelegate() external view returns (address, bytes memory);

    function factoryDepHashes() external view returns (uint256[] memory);

    /// @notice The base-system-contract hash CHANGES this hop applies (zero = leave unchanged).
    /// @dev The target release holds the complete post-upgrade hash values; these fields say
    ///      whether this hop is the one that applies them. A patch transition
    ///      (`fromRelease == newRelease`) must carry all zeros — enforced at initialization —
    ///      since targeting the same release cannot imply fresh system-contract changes.
    function baseSystemContractHashChanges() external view returns (bytes32, bytes32, bytes32);

    /// @notice Reverts unless the transition, its target release, and all codehash pins are valid.
    function validate() external view;

    function verifyAll() external view returns (bool);
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {ProposedUpgradeLib} from "../state-transition/libraries/ProposedUpgradeLib.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {CTMUpgradeComposer} from "./registry/CTMUpgradeComposer.sol";
import {ICTMRegistry} from "./registry/ICTMRegistry.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract DefaultUpgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public virtual override returns (bytes32) {
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @notice Runs an all-empty (verifier-only patch) upgrade: no facet swaps, no L2
    ///         transaction, no base-system-contract changes — the verifier is fetched from the
    ///         CTM for the new version. `ChainTypeManagerBase.createNewPatchUpgrade` commits a
    ///         cut with this 36-byte calldata so the (size-constrained) CTM carries no
    ///         `ProposedUpgrade` codecs; the empty proposal is composed here instead.
    /// @param _newProtocolVersion The new (patch-bumped) protocol version.
    function patchUpgrade(uint256 _newProtocolVersion) external returns (bytes32) {
        return upgrade(ProposedUpgradeLib.emptyProposedUpgrade(_newProtocolVersion));
    }

    /// @notice Registry-driven upgrade: composes the `ProposedUpgrade` on-chain from the pinned
    ///         registry instead of receiving it pre-built in calldata, then applies it via
    ///         {upgrade}. Same rationale as {patchUpgrade}: the committed upgrade cut carries only
    ///         `(registry, timestamp)`, so the CTM's `upgradeCutHash` commits to the registry
    ///         address (whose bytecode is the audited manifest — see `ICTMRegistry.verifyAll`)
    ///         rather than a serialized `ProposedUpgrade`. Composition happens at execution time
    ///         inside the chain diamond, where {upgrade} may be overridden to inject per-chain
    ///         L2-transaction arguments.
    /// @param _registry The pinned per-CTM registry implementation approved by governance.
    /// @param _upgradeTimestamp The timestamp after which the upgrade may execute.
    function upgradeFromRegistry(address _registry, uint256 _upgradeTimestamp) external returns (bytes32) {
        return upgrade(CTMUpgradeComposer.buildProposedUpgrade(ICTMRegistry(_registry), _upgradeTimestamp));
    }
}

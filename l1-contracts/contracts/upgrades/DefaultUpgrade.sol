// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {ProposedUpgradeLib} from "../state-transition/libraries/ProposedUpgradeLib.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

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

}

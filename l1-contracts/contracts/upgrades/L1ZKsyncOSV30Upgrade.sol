// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {L2DACommitmentScheme} from "../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L1ZKsyncOSV30Upgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        super.upgrade(_proposedUpgrade);

        // We need to reset the DA validators
        s.l1DAValidator = address(0);
        s.l2DACommitmentScheme = L2DACommitmentScheme.NONE;

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

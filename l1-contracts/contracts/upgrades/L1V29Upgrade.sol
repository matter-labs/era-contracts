// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {Diamond} from "../state-transition/libraries/Diamond.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This upgrade will be used to remove old ValidatorTimelocks from validator sets of ZKsync Chains as a part of v29 upgrade.
contract L1V29Upgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    /// @dev Doesn't require any access-control restrictions as the contract is used in the delegate call.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        address[2] memory outdatedValidatorTimelocks = [
            0x5D8ba173Dc6C3c90C8f7C04C9288BeF5FDbAd06E,
            0xa8CB082A5a689E0d594d7da1E2d72A3D63aDc1bD
        ];

        s.validators[outdatedValidatorTimelocks[0]] = false;
        s.validators[outdatedValidatorTimelocks[1]] = false;

        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

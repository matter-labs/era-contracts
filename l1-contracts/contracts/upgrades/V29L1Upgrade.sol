// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH} from "../common/Config.sol";
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract V29L1Upgrade is BaseZkSyncUpgrade {
    struct V29UpgradeParams {
        address[] oldValidatorTimelock;
        address newValidatorTimelock;
    }

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        super.upgrade(_proposedUpgrade);
        s.precommitmentForTheLatestBatch = DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    function _postUpgrade(bytes calldata _postUpgradeCalldata) internal override {
        V29UpgradeParams memory params = abi.decode(_postUpgradeCalldata, (V29UpgradeParams));
        for (uint256 i = 0; i < params.oldValidatorTimelock.length; i++) {
            s.validators[params.oldValidatorTimelock[i]] = false;
            emit IAdmin.ValidatorStatusUpdate(params.oldValidatorTimelock[i], false);
        }

        s.validators[params.newValidatorTimelock] = true;
        emit IAdmin.ValidatorStatusUpdate(params.newValidatorTimelock, true);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH} from "../common/Config.sol";
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";
import {IGetters} from "../state-transition/chain-interfaces/IGetters.sol";

error PriorityQueueNotReady();

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract L1V29Upgrade is BaseZkSyncUpgrade {
    /// @notice The parameters for the V29 upgrade.
    /// @param oldValidatorTimelocks The old validator timelocks that should be deactivated.
    /// @param newValidatorTimelock The new validator timelock that should be activated.
    /// @dev Note, that the presence of the old timelocks is not a security issue since they had a different interface,
    /// but we clean those up just in case.
    struct V29UpgradeParams {
        address[] oldValidatorTimelocks;
        address newValidatorTimelock;
    }

    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        if (IGetters(address(this)).isPriorityQueueActive() == true) {
            revert PriorityQueueNotReady();
        }
        super.upgrade(_proposedUpgrade);
        s.precommitmentForTheLatestBatch = DEFAULT_PRECOMMITMENT_FOR_THE_LAST_BATCH;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }

    /// @inheritdoc BaseZkSyncUpgrade
    function _postUpgrade(bytes calldata _postUpgradeCalldata) internal override {
        V29UpgradeParams memory params = abi.decode(_postUpgradeCalldata, (V29UpgradeParams));

        uint256 cachedLength = params.oldValidatorTimelocks.length;
        for (uint256 i = 0; i < cachedLength; ++i) {
            s.validators[params.oldValidatorTimelocks[i]] = false;
            emit IAdmin.ValidatorStatusUpdate(params.oldValidatorTimelocks[i], false);
        }

        s.validators[params.newValidatorTimelock] = true;
        emit IAdmin.ValidatorStatusUpdate(params.newValidatorTimelock, true);
    }
}

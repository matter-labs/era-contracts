// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

// solhint-disable gas-custom-errors

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {PubdataPricingMode, FeeParams} from "../state-transition/chain-deps/ZkSyncHyperchainStorage.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract Upgrade_v1_4_1 is BaseZkSyncUpgrade {
    uint32 private constant PRIORITY_TX_BATCH_OVERHEAD_L1_GAS = 1_000_000;
    uint32 private constant PRIORITY_TX_PUBDATA_PER_BATCH = 120_000;
    uint32 private constant PRIORITY_TX_MAX_GAS_PER_BATCH = 80_000_000;
    uint32 private constant PRIORITY_TX_MAX_PUBDATA = 99_000;
    uint64 private constant PRIORITY_TX_MINIMAL_GAS_PRICE = 250_000_000;

    /// This event is an exact copy of the "IAdmin.NewFeeParams" event. Since they have the same name and parameters,
    /// these will be tracked by indexers in the same manner.
    event NewFeeParams(FeeParams oldFeeParams, FeeParams newFeeParams);

    /// This function is a copy of the "Admin.changeFeeParams" function.
    /// It is to be used once to set the new fee params for the first time as they needed for the correct functioning of the upgrade.
    function changeFeeParams(FeeParams memory _newFeeParams) private {
        // Double checking that the new fee params are valid, i.e.
        // the maximal pubdata per batch is not less than the maximal pubdata per priority transaction.
        require(_newFeeParams.maxPubdataPerBatch >= _newFeeParams.priorityTxMaxPubdata, "n6");

        FeeParams memory oldFeeParams = s.feeParams;
        s.feeParams = _newFeeParams;

        emit NewFeeParams(oldFeeParams, _newFeeParams);
    }

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        // The execution of the next parts of the upgrade does depend on these fee params being already set correctly
        changeFeeParams(
            FeeParams({
                pubdataPricingMode: PubdataPricingMode.Rollup,
                batchOverheadL1Gas: PRIORITY_TX_BATCH_OVERHEAD_L1_GAS,
                maxPubdataPerBatch: PRIORITY_TX_PUBDATA_PER_BATCH,
                maxL2GasPerBatch: PRIORITY_TX_MAX_GAS_PER_BATCH,
                priorityTxMaxPubdata: PRIORITY_TX_MAX_PUBDATA,
                minimalL2GasPrice: PRIORITY_TX_MINIMAL_GAS_PRICE
            })
        );

        super.upgrade(_proposedUpgrade);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

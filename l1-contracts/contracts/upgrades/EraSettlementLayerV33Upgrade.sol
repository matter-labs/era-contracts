// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {MustBeEraChain} from "../common/L1ContractErrors.sol";
import {NotAllBatchesExecuted} from "../state-transition/L1StateTransitionErrors.sol";

/// @author Matter Labs
/// @title EraSettlementLayerV33Upgrade
/// @dev V33 upgrade for Era chains, which start requiring an Airbender proof for every batch.
/// @custom:security-contact security@matterlabs.dev
contract EraSettlementLayerV33Upgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        if (s.zksyncOS) {
            revert MustBeEraChain();
        }
        // Pre-upgrade batches are stored under the old `StoredBatchInfo` form, which only a predecessor may match.
        require(s.totalBatchesCommitted == s.totalBatchesExecuted, NotAllBatchesExecuted());

        super.upgrade(_proposedUpgrade);

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

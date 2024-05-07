// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBase} from "../state-transition/chain-deps/facets/ZkSyncHyperchainBase.sol";
import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgradeGenesis} from "./BaseZkSyncUpgradeGenesis.sol";
import {ProposedUpgrade} from "./IDefaultUpgrade.sol";
import {HyperchainCommitment} from "../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract MigrationUpgrade is ZkSyncHyperchainBase {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function migrate(
        HyperchainCommitment calldata _commitment
    ) public override returns (bytes32) {
        uint256 batchesExecuted = _commitment.totalBatchesExecuted;
        uint256 batchesVerified = _commitment.totalBatchesVerified;
        uint256 batchesCommitted = _commitment.totalBatchesCommitted;

        // Some consistency checks just in case.
        require(batchesExecuted <= batchesVerified, "Executed is not consistent with verified");
        require(batchesVerified <= batchesCommitted, "Verified is not consistent with committed");

        // In the worst case, we may need to revert all the committed batches that were not executed. 
        // This means that the stored batch hashes should be stored for [batchesExecuted; batchesCommitted] batches, i.e. 
        // there should be batchesCommitted - batchesExecuted + 1 hashes.
        require(_commitment.batchHashes.length == batchesCommitted - batchesExecuted + 1, "Invalid number of batch hashes")

        // Note that this part is done in O(N), i.e. it is the reponsibility of the admin of the chain to ensure that the total number of 
        // outstanding committed batches is not too long.
        for(uint256 i = 0 ; i < _commitment.batchHashes.length; i++) {
            s.storedBatchHashes[batchesExecuted + i] = _commitment.batchHashes[i];
        }

        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

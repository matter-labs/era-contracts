// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgrade} from "./DefaultUpgrade.sol";
import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {UnverifiedBatchesAtCommitmentUpgrade} from "./ZkSyncUpgradeErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Activates v34 chain-config commitments after all committed batches have been verified.
contract ZKsyncOSSettlementLayerV34Upgrade is DefaultUpgrade {
    /// @inheritdoc DefaultUpgrade
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        if (s.settlementLayer == address(0) && s.totalBatchesCommitted != s.totalBatchesVerified) {
            revert UnverifiedBatchesAtCommitmentUpgrade(s.totalBatchesVerified, s.totalBatchesCommitted);
        }

        return super.upgrade(_proposedUpgrade);
    }
}

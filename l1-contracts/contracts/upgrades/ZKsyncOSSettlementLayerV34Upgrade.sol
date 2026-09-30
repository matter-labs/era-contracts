// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgradeZKsyncOS} from "./DefaultUpgradeZKsyncOS.sol";
import {UnverifiedBatchesAtCommitmentUpgrade} from "./ZkSyncUpgradeErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Activates v34 chain-config commitments after all committed batches have been verified.
contract ZKsyncOSSettlementLayerV34Upgrade is DefaultUpgradeZKsyncOS {
    /// @inheritdoc DefaultUpgradeZKsyncOS
    modifier validBatchBoundary() override {
        if (s.settlementLayer == address(0) && s.totalBatchesCommitted != s.totalBatchesVerified) {
            revert UnverifiedBatchesAtCommitmentUpgrade(s.totalBatchesVerified, s.totalBatchesCommitted);
        }
        _;
    }

    /// @inheritdoc DefaultUpgradeZKsyncOS
    function getL2UpgradeTxData(
        address,
        uint256,
        bytes memory _existingTxData
    ) public pure override returns (bytes memory) {
        return _existingTxData;
    }
}

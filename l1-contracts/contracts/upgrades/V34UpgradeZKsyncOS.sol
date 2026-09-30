// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgradeZKsyncOS} from "./DefaultUpgradeZKsyncOS.sol";
import {V34UpgradeWithUnverifiedBatches} from "./ZkSyncUpgradeErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title V34UpgradeZKsyncOS
/// @notice Activates v34 chain-config commitments after all committed batches have been verified.
contract V34UpgradeZKsyncOS is DefaultUpgradeZKsyncOS {
    /// @inheritdoc DefaultUpgradeZKsyncOS
    modifier validBatchBoundary() override {
        if (s.totalBatchesCommitted != s.totalBatchesVerified) {
            revert V34UpgradeWithUnverifiedBatches(s.totalBatchesVerified, s.totalBatchesCommitted);
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

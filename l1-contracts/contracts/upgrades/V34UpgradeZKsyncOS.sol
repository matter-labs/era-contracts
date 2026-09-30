// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgradeZKsyncOS} from "./DefaultUpgradeZKsyncOS.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title V34UpgradeZKsyncOS
/// @notice The v34 per-chain upgrade. See {protocol-docs/chain-config.md}.
contract V34UpgradeZKsyncOS is DefaultUpgradeZKsyncOS {
    /// @inheritdoc DefaultUpgradeZKsyncOS
    function getL2UpgradeTxData(
        address,
        uint256,
        bytes memory _existingTxData
    ) public pure override returns (bytes memory) {
        return _existingTxData;
    }
}

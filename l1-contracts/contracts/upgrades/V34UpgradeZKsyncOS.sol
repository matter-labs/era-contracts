// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {DefaultUpgradeZKsyncOS} from "./DefaultUpgradeZKsyncOS.sol";
import {ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {IAdmin} from "../state-transition/chain-interfaces/IAdmin.sol";
import {PRIORITY_TX_MAX_GAS_LIMIT} from "../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @title V34UpgradeZKsyncOS
/// @notice The v34 per-chain upgrade: the default ZKsync OS upgrade, plus clamping the stored priority
/// transaction gas limit to the v34 ceiling. See {protocol-docs/l1-transaction-gas-limit.md}.
contract V34UpgradeZKsyncOS is DefaultUpgradeZKsyncOS {
    /// @inheritdoc DefaultUpgradeZKsyncOS
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32 result) {
        result = super.upgrade(_proposedUpgrade);

        uint256 oldPriorityTxMaxGasLimit = s.priorityTxMaxGasLimit;
        if (oldPriorityTxMaxGasLimit > PRIORITY_TX_MAX_GAS_LIMIT) {
            s.priorityTxMaxGasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
            emit IAdmin.NewPriorityTxMaxGasLimit(oldPriorityTxMaxGasLimit, PRIORITY_TX_MAX_GAS_LIMIT);
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {NonEmptyCalldata} from "../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract DefaultUpgrade is BaseZkSyncUpgrade {
    /// @notice The main function that will be delegate-called by the chain.
    /// @param _proposedUpgrade The upgrade to be executed.
    /// @dev `DefaultUpgrade` does not override `_upgradeL1Contract` or `_postUpgrade`, so any calldata
    /// targeting those hooks (`l1ContractsUpgradeCalldata`, `postUpgradeCalldata`) would be silently
    /// discarded while the protocol version is still incremented. Reject such calldata so a governance
    /// action that expected it to be applied fails loudly instead of completing as a partial no-op.
    /// Upgrades that need this calldata must use a dedicated upgrade contract (e.g. `L1V29Upgrade`).
    function upgrade(ProposedUpgrade memory _proposedUpgrade) public override returns (bytes32) {
        if (
            _proposedUpgrade.l1ContractsUpgradeCalldata.length != 0 || _proposedUpgrade.postUpgradeCalldata.length != 0
        ) {
            revert NonEmptyCalldata();
        }
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

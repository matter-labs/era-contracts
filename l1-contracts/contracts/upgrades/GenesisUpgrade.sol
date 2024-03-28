// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgradeGenesis} from "./BaseZkSyncUpgradeGenesis.sol";
import {ProposedUpgrade} from "./IDefaultUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract GenesisUpgrade is BaseZkSyncUpgradeGenesis {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

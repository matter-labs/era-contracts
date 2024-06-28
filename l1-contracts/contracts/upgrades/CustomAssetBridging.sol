// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This upgrade will be used to migrate Era to be part of the hyperchain ecosystem contracts.
contract CustomAssetBridging is BaseZkSyncUpgrade {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        // (uint256 chainId, address bridgehubAddress, address stateTransitionManager, address sharedBridgeAddress) = abi
        //     .decode(_proposedUpgrade.postUpgradeCalldata, (uint256, address, address, address));

        // s.baseTokenAssetId =

        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

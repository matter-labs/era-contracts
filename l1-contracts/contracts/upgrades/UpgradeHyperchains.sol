// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract UpgradeHyperchains is BaseZkSyncUpgrade {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgradeWithAdditionalData(
        ProposedUpgrade calldata _proposedUpgrade,
        bytes calldata _additionalData
    ) public returns (bytes32) {
        (uint256 chainId, address bridgehubAddress, address stateTransitionManager, address sharedBridgeAddress) = abi
            .decode(_additionalData, (uint256, address, address, address));
        // Check to make sure that the new blob versioned hash address is not the zero address.
        require(sharedBridgeAddress != address(0), "b9");

        s.chainId = chainId;
        s.bridgehub = bridgehubAddress;
        s.stateTransitionManager = stateTransitionManager;
        s.baseTokenBridge = sharedBridgeAddress;
        s.baseToken = 0x0000000000000000000000000000000000000001;
        s.baseTokenGasPriceMultiplierNominator = 1;
        s.baseTokenGasPriceMultiplierDenominator = 1;

        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

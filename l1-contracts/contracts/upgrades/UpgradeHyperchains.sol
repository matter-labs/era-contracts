// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Diamond} from "../state-transition/libraries/Diamond.sol";
import {BaseZkSyncUpgrade, ProposedUpgrade} from "./BaseZkSyncUpgrade.sol";
import {ETH_TOKEN_ADDRESS} from "../common/Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice This upgrade will be used to migrate Era to be part of the hyperchain ecosystem contracts.
contract UpgradeHyperchains is BaseZkSyncUpgrade {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param _proposedUpgrade The upgrade to be executed.
    function upgrade(ProposedUpgrade calldata _proposedUpgrade) public override returns (bytes32) {
        (uint256 chainId, address bridgehubAddress, address stateTransitionManager, address sharedBridgeAddress) = abi
            .decode(_proposedUpgrade.postUpgradeCalldata, (uint256, address, address, address));
        require(chainId != 0, "UpgradeHyperchain: 1");
        require(bridgehubAddress != address(0), "UpgradeHyperchain: 2");
        require(stateTransitionManager != address(0), "UpgradeHyperchain: 3");
        require(sharedBridgeAddress != address(0), "UpgradeHyperchain: 4");

        s.chainId = chainId;
        s.bridgehub = bridgehubAddress;
        s.stateTransitionManager = stateTransitionManager;
        s.baseTokenBridge = sharedBridgeAddress;
        s.baseToken = ETH_TOKEN_ADDRESS;
        s.baseTokenGasPriceMultiplierNominator = 1;
        s.baseTokenGasPriceMultiplierDenominator = 1;

        super.upgrade(_proposedUpgrade);
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

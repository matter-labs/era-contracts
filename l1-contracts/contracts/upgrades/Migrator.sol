// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZkSyncHyperchainBase} from "../state-transition/chain-deps/facets/ZkSyncHyperchainBase.sol";
import {StateTransitionManager} from "../state-transition/StateTransitionManager.sol";
import {Bridgehub} from "../bridgehub/Bridgehub.sol";
import {IVerifier} from "../state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "../state-transition/libraries/Diamond.sol";

struct MigrationParams {
    address newVerifier;
    address newCTM;
    address newValidatorTimelock;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract Migrator is ZkSyncHyperchainBase {
    /// @notice The main function that will be called by the upgrade proxy.
    /// @param params The migration params
    function upgrade(MigrationParams memory params) public returns (bytes32) {
        address currentTimelock = StateTransitionManager(s.stateTransitionManager).validatorTimelock();

        address newBridgehub = StateTransitionManager(s.stateTransitionManager).BRIDGE_HUB();
        address newL1SharedBridge = address(Bridgehub(newBridgehub).sharedBridge());

        s.validators[currentTimelock] = false;
        s.validators[params.newValidatorTimelock] = true;

        s.verifier = IVerifier(params.newVerifier);

        s.bridgehub = newBridgehub;
        s.stateTransitionManager = params.newCTM;
        s.baseTokenBridge = newL1SharedBridge;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

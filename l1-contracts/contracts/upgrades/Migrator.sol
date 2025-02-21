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
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract Migrator is ZkSyncHyperchainBase {

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param params The migration params
    function upgrade(MigrationParams memory params) public returns (bytes32) {
        address currentCTM = StateTransitionManager(s.stateTransitionManager).validatorTimelock();
        address currentTimelock = StateTransitionManager(params.newCTM).validatorTimelock();
        address currentBridgehub = StateTransitionManager(s.stateTransitionManager).BRIDGE_HUB();
        address currentL1SharedBridge = address(Bridgehub(currentBridgehub).sharedBridge());

        s.validators[currentCTM] = false;
        s.validators[currentTimelock] = true;

        s.verifier = IVerifier(params.newVerifier);

        s.bridgehub = currentBridgehub;
        s.stateTransitionManager = params.newCTM;
        s.baseTokenBridge = currentL1SharedBridge;
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

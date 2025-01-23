// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;


import {ZkSyncHyperchainBase} from "../state-transition/chain-deps/facets/ZkSyncHyperchainBase.sol";
import {StateTransitionManager} from "../state-transition/StateTransitionManager.sol";
import {Bridgehub} from "../bridgehub/Bridgehub.sol";
import {IVerifier} from "../state-transition/chain-interfaces/IVerifier.sol";
import {Diamond} from "../state-transition/libraries/Diamond.sol";

struct MigrationParams {
    address newCTM;
    address newBridgehub;
    address newVerifier;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract Migrator is ZkSyncHyperchainBase {
    event BlockStateInfo(uint256 committed, uint256 proved, uint256 executed);

    /// @notice The main function that will be called by the upgrade proxy.
    /// @param params The migration params
    function upgrade(MigrationParams memory params) public returns (bytes32) {
        address currentCTM = StateTransitionManager(s.stateTransitionManager).validatorTimelock();
        address newTimelock = StateTransitionManager(params.newCTM).validatorTimelock();

        s.validators[currentCTM] = false;
        s.validators[newTimelock] = true;

        s.verifier = IVerifier(params.newVerifier);

        emit BlockStateInfo(s.totalBatchesCommitted, s.totalBatchesVerified, s.totalBatchesExecuted);
    
        s.bridgehub = params.newBridgehub;
        s.stateTransitionManager = params.newCTM;
        s.baseTokenBridge = address(Bridgehub(params.newBridgehub).sharedBridge());
        return Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE;
    }
}

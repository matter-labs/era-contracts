// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {ZkSyncStateTransitionBase} from "solpp/state-transition/chain-deps/facets/Admin.sol";

contract BaseFacetWrapper is ZkSyncStateTransitionBase {
    // === Util functions ===
    function util_setGovernor(address _governor) external {
        s.governor = _governor;
    }

    function util_getGovernor() external view returns (address) {
        return s.governor;
    }

    function util_setValidatorStatus(address _validator, bool _active) external {
        s.validators[_validator] = _active;
    }

    function util_getValidatorStatus(address _validator) external view returns (bool) {
        return s.validators[_validator];
    }

    function util_setStateTransitionManager(address _stateTransitionManager) external {
        s.stateTransitionManager = _stateTransitionManager;
    }

    function util_getStateTransitionManager() external view returns (address) {
        return s.stateTransitionManager;
    }

    function util_setBridgehub(address _bridgehub) external {
        s.bridgehub = _bridgehub;
    }

    function util_getBridgehub() external view returns (address) {
        return s.bridgehub;
    }

    // === Modifier test functions ===
    function functionWithOnlyGovernorModifier() external onlyGovernor {}

    function functionWithOnlyValidatorModifier() external onlyValidator {}

    function functionWithOnlyStateTransitionManagerModifier() external onlyStateTransitionManager {}

    function functionWithOnlyBridgehubModifier() external onlyBridgehub {}

    function functionWithOnlyGovernorOrStateTransitionManagerModifier() external onlyGovernorOrStateTransitionManager {}
}

bytes constant ERROR_ONLY_GOVERNOR = "StateTransition Chain: not governor";
bytes constant ERROR_ONLY_VALIDATOR = "StateTransition Chain: not validator";
bytes constant ERROR_ONLY_STATE_TRANSITION_MANAGER = "StateTransition Chain: not state transition manager";
bytes constant ERROR_ONLY_BRIDGEHUB = "StateTransition Chain: not bridgehub";
bytes constant ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER = "StateTransition Chain: Only by governor or state transition manager";

contract ZkSyncStateTransitionBaseTest is Test {
    ZkSyncStateTransitionBase internal baseFacet;
    BaseFacetWrapper internal baseFacetWrapper;

    function setUp() public virtual {
        baseFacetWrapper = new BaseFacetWrapper();
        baseFacet = ZkSyncStateTransitionBase(baseFacetWrapper);
    }
}

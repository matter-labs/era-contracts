// SPDX-License-Identifier: MIT
pragma solidity 0.8.20;

import {Test} from "forge-std/Test.sol";

import {AdminFacet} from "solpp/state-transition/chain-deps/facets/Admin.sol";
import {Diamond} from "solpp/state-transition/libraries/Diamond.sol";
import {FeeParams} from "solpp/state-transition/chain-deps/ZkSyncStateTransitionStorage.sol";
import {IAdmin} from "solpp/state-transition/chain-interfaces/IAdmin.sol";

contract AdminWrapper is AdminFacet {
    function util_setPendingGovernor(address _pendingGovernor) external {
        s.governor = _pendingGovernor;
    }

    function util_getPendingGovernor() external view returns (address) {
        return s.pendingGovernor;
    }

    function util_setGovernor(address _governor) external {
        s.governor = _governor;
    }

    function util_getGovernor() external view returns (address) {
        return s.governor;
    }

    function util_setPendingAdmin(address _pendingAdmin) external {
        s.pendingAdmin = _pendingAdmin;
    }

    function util_getPendingAdmin() external view returns (address) {
        return s.pendingAdmin;
    }

    function util_setAdmin(address _admin) external {
        s.admin = _admin;
    }

    function util_getAdmin() external view returns (address) {
        return s.admin;
    }

    function util_setValidator(address _validator, bool _active) external {
        s.validators[_validator] = _active;
    }

    function util_getValidator(address _validator) external view returns (bool) {
        return s.validators[_validator];
    }

    function util_setZkPorterAvailability(bool _available) external {
        s.zkPorterIsAvailable = _available;
    }

    function util_getZkPorterAvailability() external view returns (bool) {
        return s.zkPorterIsAvailable;
    }

    function util_setStateTransitionManager(address _stateTransitionManager) external {
        s.stateTransitionManager = _stateTransitionManager;
    }

    function util_getStateTransitionManager() external view returns (address) {
        return s.stateTransitionManager;
    }

    function util_setPriorityTxMaxGasLimit(uint256 _priorityTxMaxGasLimit) external {
        s.priorityTxMaxGasLimit = _priorityTxMaxGasLimit;
    }

    function util_getPriorityTxMaxGasLimit() external view returns (uint256) {
        return s.priorityTxMaxGasLimit;
    }

    function util_setFeeParams(FeeParams calldata _feeParams) external {
        s.feeParams = _feeParams;
    }

    function util_getFeeParams() external view returns (FeeParams memory) {
        return s.feeParams;
    }

    function util_setProtocolVersion(uint256 _protocolVersion) external {
        s.protocolVersion = _protocolVersion;
    }

    function util_getProtocolVersion() external view returns (uint256) {
        return s.protocolVersion;
    }

    function util_setIsFrozen(bool _isFrozen) external {
        Diamond.DiamondStorage storage s = Diamond.getDiamondStorage();
        s.isFrozen = _isFrozen;
    }

    function util_getIsFrozen() external view returns (bool) {
        Diamond.DiamondStorage storage s = Diamond.getDiamondStorage();
        return s.isFrozen;
    }
}

bytes constant ERROR_ONLY_GOVERNOR = "StateTransition Chain: not governor";
bytes constant ERROR_ONLY_ADMIN_OR_GOVERNOR = "StateTransition chain: Only by governor or admin";
bytes constant ERROR_ONLY_STATE_TRANSITION_MANAGER = "StateTransition Chain: not state transition manager";
bytes constant ERROR_ONLY_GOVERNOR_OR_STATE_TRANSITION_MANAGER = "StateTransition Chain: Only by governor or state transition manager";

contract AdminTest is Test {
    IAdmin internal adminFacet;
    AdminWrapper internal adminFacetWrapper;

    function setUp() public virtual {
        adminFacetWrapper = new AdminWrapper();
        adminFacet = IAdmin(adminFacetWrapper);
    }
}

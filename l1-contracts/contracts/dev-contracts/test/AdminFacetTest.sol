// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {AdminFacet} from "../../state-transition/chain-deps/facets/Admin.sol";

contract AdminFacetTest is AdminFacet {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor() {
        s.admin = msg.sender;
        s.stateTransitionManager = msg.sender;
    }

    function getPorterAvailability() external view returns (bool) {
        return s.zkPorterIsAvailable;
    }

    function isValidator(address _validator) external view returns (bool) {
        return s.validators[_validator];
    }

    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return s.priorityTxMaxGasLimit;
    }

    function getAdmin() external view returns (address) {
        return s.admin;
    }

    function getPendingAdmin() external view returns (address) {
        return s.pendingAdmin;
    }
}

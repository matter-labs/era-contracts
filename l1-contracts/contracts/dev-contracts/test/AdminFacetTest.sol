// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../zksync/facets/Admin.sol";

contract AdminFacetTest is AdminFacet {
    constructor() {
        s.governor = msg.sender;
    }

    function getPorterAvailability() external view returns (bool) {
        return s.zkPorterIsAvailable;
    }

    function isValidator(address _address) external view returns (bool) {
        return s.validators[_address];
    }

    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return s.priorityTxMaxGasLimit;
    }

    function getGovernor() external view returns (address) {
        return s.governor;
    }

    function getPendingGovernor() external view returns (address) {
        return s.pendingGovernor;
    }
}

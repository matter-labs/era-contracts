// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/chain-deps/facets/Admin.sol";

contract AdminFacetTest is AdminFacet {
    constructor() {
        chainStorage.governor = msg.sender;
    }

    function getPorterAvailability() external view returns (bool) {
        return chainStorage.zkPorterIsAvailable;
    }

    function isValidator(address _address) external view returns (bool) {
        return chainStorage.validators[_address];
    }

    function getPriorityTxMaxGasLimit() external view returns (uint256) {
        return chainStorage.priorityTxMaxGasLimit;
    }

    function getGovernor() external view returns (address) {
        return chainStorage.governor;
    }

    function getPendingGovernor() external view returns (address) {
        return chainStorage.pendingGovernor;
    }
}

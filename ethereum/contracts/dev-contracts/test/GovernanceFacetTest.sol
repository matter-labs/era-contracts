// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../zksync/facets/Governance.sol";

contract GovernanceFacetTest is GovernanceFacet {
    constructor() {
        s.governor = msg.sender;
    }

    function isValidator(address _validator) external view returns (bool) {
        return s.validators[_validator];
    }

    function getPendingGovernor() external view returns (address) {
        return s.pendingGovernor;
    }

    function getGovernor() external view returns (address) {
        return s.governor;
    }
}

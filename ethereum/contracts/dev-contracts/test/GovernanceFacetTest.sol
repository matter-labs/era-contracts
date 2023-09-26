// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../proof-system/chain-deps/facets/Governance.sol";

contract GovernanceFacetTest is GovernanceFacet {
    constructor() {
        chainStorage.governor = msg.sender;
    }

    function getPendingGovernor() external view returns (address) {
        return chainStorage.pendingGovernor;
    }

    function getGovernor() external view returns (address) {
        return chainStorage.governor;
    }
}

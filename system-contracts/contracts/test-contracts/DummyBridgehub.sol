// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

contract DummyBridgehub {
    address public owner;

    constructor(uint256 _l1ChainId, address _aliasedL1Governance, uint256 _maxNumberOfZKChains) {
        owner = _aliasedL1Governance;
    }
}

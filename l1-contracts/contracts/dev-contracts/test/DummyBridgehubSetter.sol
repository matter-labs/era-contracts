// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1Bridgehub} from "../../bridgehub/L1Bridgehub.sol";

contract DummyBridgehubSetter is L1Bridgehub {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    /// @notice Constructor
    constructor(address _owner, uint256 _maxNumberOfZKChains) L1Bridgehub(_owner, _maxNumberOfZKChains) {}

    function setZKChain(uint256 _chainId, address _zkChain) external {
        _registerNewZKChain(_chainId, _zkChain, true);
    }

    function setCTM(uint256 _chainId, address _ctm) external {
        chainTypeManager[_chainId] = _ctm;
    }
}

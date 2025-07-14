// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Bridgehub} from "../../bridgehub/Bridgehub.sol";

contract DummyBridgehubSetter is Bridgehub {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    /// @notice Constructor
    constructor(
        uint256 _l1ChainId,
        address _owner,
        uint256 _maxNumberOfZKChains
    ) Bridgehub(_l1ChainId, _owner, _maxNumberOfZKChains) {}

    function setZKChain(uint256 _chainId, address _zkChain) external {
        _registerNewZKChain(_chainId, _zkChain, true);
    }

    function setCTM(uint256 _chainId, address _ctm) external {
        chainTypeManager[_chainId] = _ctm;
    }
}

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
        uint256 _maxNumberOfHyperchains
    ) Bridgehub(_l1ChainId, _owner, _maxNumberOfHyperchains) {}

    function setHyperchain(uint256 _chainId, address _hyperchain) external {
        _registerNewHyperchain(_chainId, _hyperchain);
    }

    function setSTM(uint256 _chainId, address _stm) external {
        stateTransitionManager[_chainId] = _stm;
    }
}

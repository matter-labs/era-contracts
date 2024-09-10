// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

<<<<<<< HEAD
import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDRESS} from "../../common/L2ContractAddresses.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";

import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";

contract DummyBridgehub {
    IMessageRoot public messageRoot;

    // add this to be excluded from coverage report
    function test() internal virtual {}

    function baseTokenAssetId(uint256) external view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    L2_NATIVE_TOKEN_VAULT_ADDRESS,
                    ETH_TOKEN_ADDRESS
                    // bytes32(uint256(uint160(IGetters(msg.sender).getBaseToken())))
                )
            );
    }

    function setMessageRoot(address _messageRoot) public {
        messageRoot = IMessageRoot(_messageRoot);
=======
import {Bridgehub} from "../../bridgehub/Bridgehub.sol";

/// @title DummyBridgehub
/// @notice A test smart contract that allows to set State Transition Manager for a given chain
contract DummyBridgehub is Bridgehub {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    constructor() Bridgehub() {}

    function setStateTransitionManager(uint256 _chainId, address _stm) external {
        stateTransitionManager[_chainId] = _stm;
>>>>>>> 874bc6ba940de9d37b474d1e3dda2fe4e869dfbe
    }
}

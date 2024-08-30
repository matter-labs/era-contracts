// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {L2_NATIVE_TOKEN_VAULT_ADDR} from "../../common/L2ContractAddresses.sol";
import {IMessageRoot} from "../../bridgehub/IMessageRoot.sol";

import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";

/// @title DummyBridgehub
/// @notice A test smart contract that allows to set State Transition Manager for a given chain
contract DummyBridgehub {
    IMessageRoot public messageRoot;

    address public hyperchain;

    // add this to be excluded from coverage report
    function test() internal virtual {}

    function baseTokenAssetId(uint256) external view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    L2_NATIVE_TOKEN_VAULT_ADDR,
                    ETH_TOKEN_ADDRESS
                    // bytes32(uint256(uint160(IGetters(msg.sender).getBaseToken())))
                )
            );
    }

    function setMessageRoot(address _messageRoot) public {
        messageRoot = IMessageRoot(_messageRoot);
    }

    function setHyperchain(uint256, address _hyperchain) external {
        hyperchain = _hyperchain;
    }

    function getHyperchain(uint256) external view returns (address) {
        return address(0);
    }
}

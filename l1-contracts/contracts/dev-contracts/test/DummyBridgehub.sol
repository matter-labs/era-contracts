// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS, ETH_TOKEN_ADDRESS} from "../../common/Config.sol";
import {IGetters} from "../../state-transition/chain-interfaces/IGetters.sol";

contract DummyBridgehub {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function baseTokenAssetId(uint256) external view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    block.chainid,
                    NATIVE_TOKEN_VAULT_VIRTUAL_ADDRESS,
                    ETH_TOKEN_ADDRESS
                    // bytes32(uint256(uint160(IGetters(msg.sender).getBaseToken())))
                )
            );
    }
}

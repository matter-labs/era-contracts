// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {BridgeHelper} from "../../bridge/BridgeHelper.sol";

contract BridgeHelperTest {
    function callGetters(address _token, uint256 _originChainId) external view returns (bytes memory) {
        return BridgeHelper.getERC20Getters(_token, _originChainId);
    }
}

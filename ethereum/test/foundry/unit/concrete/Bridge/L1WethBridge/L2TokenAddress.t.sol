// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L1WethBridgeTest} from "./_L1WethBridge_Shared.t.sol";

contract L2TokenAddressTest is L1WethBridgeTest {
    function test_l1TokenSameAsL1WethAddress() public {
        address l1Token = address(l1Weth);

        address l2Token = bridgeProxy.l2TokenAddress(l1Token);

        address expectedAddress = bridgeProxy.l2WethAddress();
        bool isSameAddress = l2Token == expectedAddress;
        assertTrue(isSameAddress, "l2TokenAddress != l2WethAddress");
    }

    function test_l1TokenNotSameAsL1WethAddress() public {
        address l1Token = makeAddr("l1Token");

        address l2Token = bridgeProxy.l2TokenAddress(l1Token);

        address expectedAddress = address(0);
        bool isSameAddress = l2Token == expectedAddress;
        assertTrue(isSameAddress, "l2TokenAddress != address(0)");
    }
}

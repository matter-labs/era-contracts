// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {Vm} from "forge-std/Test.sol";
import {L1WethBridgeTest} from "./_L1WethBridge_Shared.t.sol";

contract ReceiveTest is L1WethBridgeTest {
    function test_ReceiveEthFromL1WethAddress() public {
        uint256 amount = 10000;

        hoax(address(l1Weth));

        vm.recordLogs();

        (bool success, ) = payable(address(bridgeProxy)).call{value: amount}("");
        require(success, "received unexpected revert");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].topics.length, 1);
        assertEq(entries[0].topics[0], keccak256("EthReceived(uint256)"));
        assertEq(abi.decode(entries[0].data, (uint256)), amount);
    }

    function test_ReceiveEthFromZkSyncAddress() public {
        uint256 amount = 10000;

        hoax(address(bridgeProxy.zkSync()));

        vm.recordLogs();

        (bool success, ) = payable(address(bridgeProxy)).call{value: amount}("");
        require(success, "received unexpected revert");

        Vm.Log[] memory entries = vm.getRecordedLogs();
        assertEq(entries.length, 1);
        assertEq(entries[0].topics.length, 1);
        assertEq(entries[0].topics[0], keccak256("EthReceived(uint256)"));
        assertEq(abi.decode(entries[0].data, (uint256)), amount);
    }

    function test_RevertWhen_ReceiveEthFromRandomAddress() public {
        uint256 amount = 10000;

        hoax(randomSigner);

        vm.expectRevert(bytes.concat("pn"));
        (bool revertAsExpected, ) = payable(address(bridgeProxy)).call{value: amount}("");
        assertTrue(revertAsExpected, "expectRevert: call did not revert");
    }
}

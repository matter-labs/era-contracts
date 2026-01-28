// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "forge-std/Test.sol";
import {L1_MESSENGER_HOOK} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import "contracts/l2-system/zksync-os/L1Messenger.sol";
import {IL2ToL1MessengerZKSyncOS} from "contracts/common/l2-helpers/IL2ToL1MessengerZKSyncOS.sol";

contract L1MessengerTest is Test {
    L1Messenger messenger;

    function setUp() public {
        messenger = new L1Messenger();
    }

    function test_sendToL1_works_andEmitsEvent() public {
        bytes memory message = hex"aaaaaaaaaaaaaaaa"; // arbitrary payload
        bytes32 expectedHash = keccak256(message);

        // The hook is called with abi.encodePacked(msg.sender, _message)
        bytes memory hookCalldata = abi.encodePacked(address(this), message);

        // Mock the system hook call to always succeed and return empty bytes
        vm.mockCall(
            L1_MESSENGER_HOOK,
            hookCalldata,
            "" // return data (unused)
        );

        // Expect the event
        // expectEmit(checkTopic1, checkTopic2, checkTopic3, checkData)
        // Only `sender` is indexed; `hash` and `message` are in data.
        vm.expectEmit(true, false, false, true);
        emit IL2ToL1MessengerZKSyncOS.L1MessageSent(address(this), expectedHash, message);

        uint256 gasBefore = gasleft();
        bytes32 retHash = messenger.sendToL1(message);
        uint256 gasAfter = gasleft();

        uint256 gasUsed = gasBefore - gasAfter;
        emit log_named_uint("gas used by sendToL1", gasUsed);

        assertEq(retHash, expectedHash, "returned hash mismatch");
    }
}

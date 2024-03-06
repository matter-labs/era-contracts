// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

contract FinalizeWithdrawalTest is L1Erc20BridgeTest {
    using stdStorage for StdStorage;

    event WithdrawalFinalized(address indexed to, address indexed l1Token, uint256 amount);

    function test_RevertWhen_withdrawalFinalized() public {
        uint256 l2BatchNumber = 0;
        uint256 l2MessageIndex = 1;
        stdstore
            .target(address(bridge))
            .sig("isWithdrawalFinalized(uint256,uint256)")
            .with_key(l2BatchNumber)
            .with_key(l2MessageIndex)
            .checked_write(true);

        assertTrue(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));

        vm.expectRevert(bytes("pw"));
        bytes32[] memory merkleProof;
        bridge.finalizeWithdrawal(l2BatchNumber, l2MessageIndex, 0, "", merkleProof);
    }

    function test_finalizeWithdrawalSuccessfully() public {
        uint256 l2BatchNumber = 3;
        uint256 l2MessageIndex = 4;
        uint256 amount = 999;

        assertFalse(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));

        dummySharedBridge.setDataToBeReturnedInFinalizeWithdrawal(alice, address(token), amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit WithdrawalFinalized(alice, address(token), amount);
        bytes32[] memory merkleProof;
        bridge.finalizeWithdrawal(l2BatchNumber, l2MessageIndex, 0, "", merkleProof);

        // withdrawal finalization should be handled in the shared bridge, so it shouldn't
        // change in the  L1 ERC20 bridge after finalization.
        assertFalse(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));
    }
}

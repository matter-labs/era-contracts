// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

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
        bridge.finalizeWithdrawal({
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: 0,
            _message: "",
            _merkleProof: merkleProof
        });
    }

    function test_finalizeWithdrawalSuccessfully() public {
        uint256 l2BatchNumber = 3;
        uint256 l2MessageIndex = 4;
        uint256 amount = 999;

        assertFalse(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));

        dummySharedBridge.setDataToBeReturnedInFinalizeWithdrawal(alice, address(token), amount);

        vm.prank(alice);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(bridge));
        emit WithdrawalFinalized(alice, address(token), amount);
        bytes32[] memory merkleProof;
        bridge.finalizeWithdrawal({
            _l2BatchNumber: l2BatchNumber,
            _l2MessageIndex: l2MessageIndex,
            _l2TxNumberInBatch: 0,
            _message: "",
            _merkleProof: merkleProof
        });

        // withdrawal finalization should be handled in the shared bridge, so it shouldn't
        // change in the  L1 ERC20 bridge after finalization.
        assertFalse(bridge.isWithdrawalFinalized(l2BatchNumber, l2MessageIndex));
    }
}

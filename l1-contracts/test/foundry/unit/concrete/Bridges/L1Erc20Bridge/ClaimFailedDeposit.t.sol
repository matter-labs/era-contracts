// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";

contract ClaimFailedDepositTest is L1Erc20BridgeTest {
    using stdStorage for StdStorage;

    event ClaimedFailedDeposit(address indexed to, address indexed l1Token, uint256 amount);

    function test_RevertWhen_ClaimAmountIsZero() public {
        vm.expectRevert(bytes("2T"));
        bytes32[] memory merkleProof;
        bridge.claimFailedDeposit(randomSigner, address(token), dummyL2DepositTxHash, 0, 0, 0, merkleProof);
    }

    function test_claimFailedDepositSuccessfully() public {
        uint256 depositedAmountBefore = bridge.depositAmount(alice, address(token), dummyL2DepositTxHash);
        assertEq(depositedAmountBefore, 0);

        uint256 amount = 16;
        stdstore
            .target(address(bridge))
            .sig("depositAmount(address,address,bytes32)")
            .with_key(alice)
            .with_key(address(token))
            .with_key(dummyL2DepositTxHash)
            .checked_write(amount);

        uint256 depositedAmountAfterDeposit = bridge.depositAmount(alice, address(token), dummyL2DepositTxHash);
        assertEq(depositedAmountAfterDeposit, amount);

        vm.prank(alice);
        vm.expectEmit(true, true, true, true, address(bridge));
        emit ClaimedFailedDeposit(alice, address(token), amount);
        bytes32[] memory merkleProof;
        bridge.claimFailedDeposit(alice, address(token), dummyL2DepositTxHash, 0, 0, 0, merkleProof);

        uint256 depositedAmountAfterWithdrawal = bridge.depositAmount(alice, address(token), dummyL2DepositTxHash);
        assertEq(depositedAmountAfterWithdrawal, 0);
    }
}

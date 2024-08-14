// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {L1Erc20BridgeTest} from "./_L1Erc20Bridge_Shared.t.sol";
import {StdStorage, stdStorage} from "forge-std/Test.sol";
import {IL1SharedBridge} from "contracts/bridge/interfaces/IL1SharedBridge.sol";

contract ClaimFailedDepositTest is L1Erc20BridgeTest {
    using stdStorage for StdStorage;

    event ClaimedFailedDeposit(address indexed to, address indexed l1Token, uint256 amount);

    function test_RevertWhen_ClaimAmountIsZero() public {
        vm.expectRevert(bytes("2T"));
        bytes32[] memory merkleProof;

        bridge.claimFailedDeposit({
            _depositSender: randomSigner,
            _l1Token: address(token),
            _l2TxHash: bytes32(""),
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _merkleProof: merkleProof
        });
    }

    function test_claimFailedDepositSuccessfully() public {
        uint256 amount = 16;
        bytes32 l2DepositTxHash = keccak256("l2tx");
        bytes32[] memory merkleProof;

        uint256 depositedAmountBefore = bridge.depositAmount(alice, address(token), l2DepositTxHash);
        assertEq(depositedAmountBefore, 0);

        stdstore
            .target(address(bridge))
            .sig("depositAmount(address,address,bytes32)")
            .with_key(alice)
            .with_key(address(token))
            .with_key(l2DepositTxHash)
            .checked_write(amount);

        uint256 depositedAmountAfterDeposit = bridge.depositAmount(alice, address(token), l2DepositTxHash);
        assertEq(depositedAmountAfterDeposit, amount);

        vm.mockCall(
            sharedBridgeAddress,
            abi.encodeWithSelector(
                IL1SharedBridge.claimFailedDepositLegacyErc20Bridge.selector,
                alice,
                address(token),
                amount,
                l2DepositTxHash,
                0,
                0,
                0,
                merkleProof
            ),
            abi.encode("")
        );

        vm.prank(alice);
        // solhint-disable-next-line func-named-parameters
        vm.expectEmit(true, true, true, true, address(bridge));
        emit ClaimedFailedDeposit(alice, address(token), amount);

        bridge.claimFailedDeposit({
            _depositSender: alice,
            _l1Token: address(token),
            _l2TxHash: l2DepositTxHash,
            _l2BatchNumber: 0,
            _l2MessageIndex: 0,
            _l2TxNumberInBatch: 0,
            _merkleProof: merkleProof
        });

        uint256 depositedAmountAfterWithdrawal = bridge.depositAmount(alice, address(token), l2DepositTxHash);
        assertEq(depositedAmountAfterWithdrawal, 0);
    }
}

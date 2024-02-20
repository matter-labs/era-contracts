// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";

import {IMailbox} from "solpp/state-transition/chain-interfaces/IMailbox.sol";

contract IsEthWithdrawalFinalizedTest is BridgehubMailboxTest {
    // uint256 internal l2MessageIndex;
    // uint256 internal l2TxNumberInBlock;
    // function setUp() public {
    //     l2MessageIndex = 123456789;
    //     l2TxNumberInBlock = 23456;
    // }
    // function test_WhenChainContractReturnsTrue() public {
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock),
    //         abi.encode(true)
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock)
    //     );
    //     bool res = bridgehub.isEthWithdrawalFinalized(chainId, l2MessageIndex, l2TxNumberInBlock);
    //     assertEq(res, true, "ETH withdrawal should be finalized");
    // }
    // function test_WhenChainContractReturnsFalse() public {
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock),
    //         abi.encode(false)
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.isEthWithdrawalFinalized.selector, l2MessageIndex, l2TxNumberInBlock)
    //     );
    //     bool res = bridgehub.isEthWithdrawalFinalized(chainId, l2MessageIndex, l2TxNumberInBlock);
    //     assertEq(res, false, "ETH withdrawal should not be finalized");
    // }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";

import {IMailbox} from "solpp/state-transition/chain-interfaces/IMailbox.sol";

contract FinalizeEthWithdrawalTest is BridgehubMailboxTest {
    // uint256 internal l2BlockNumber;
    // uint256 internal l2MessageIndex;
    // uint16 internal l2TxNumberInBlock;
    // bytes internal message;
    // bytes32[] internal merkleProof;
    // address internal msgSender;
    // function setUp() public {
    //     l2BlockNumber = 3456789;
    //     l2MessageIndex = 234567890;
    //     l2TxNumberInBlock = 12345;
    //     message = "message";
    //     merkleProof = new bytes32[](1);
    //     msgSender = makeAddr("msgSender");
    // }
    // function test_RevertWhen_InternalCallReverts() public {
    //     bytes memory revertMessage = "random revert";
    //     vm.mockCallRevert(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.finalizeEthWithdrawalBridgehub.selector,
    //             msgSender,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             message,
    //             merkleProof
    //         ),
    //         revertMessage
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.finalizeEthWithdrawalBridgehub.selector,
    //             msgSender,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             message,
    //             merkleProof
    //         )
    //     );
    //     vm.expectRevert(revertMessage);
    //     vm.startPrank(msgSender);
    //     bridgehub.finalizeEthWithdrawal(
    //         chainId,
    //         l2BlockNumber,
    //         l2MessageIndex,
    //         l2TxNumberInBlock,
    //         message,
    //         merkleProof
    //     );
    // }
    // function test_ShouldReturnReceivedCanonicalTxHash() public {
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.finalizeEthWithdrawalBridgehub.selector,
    //             msgSender,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             message,
    //             merkleProof
    //         ),
    //         ""
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.finalizeEthWithdrawalBridgehub.selector,
    //             msgSender,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             message,
    //             merkleProof
    //         )
    //     );
    //     vm.startPrank(msgSender);
    //     bridgehub.finalizeEthWithdrawal(
    //         chainId,
    //         l2BlockNumber,
    //         l2MessageIndex,
    //         l2TxNumberInBlock,
    //         message,
    //         merkleProof
    //     );
    // }
}

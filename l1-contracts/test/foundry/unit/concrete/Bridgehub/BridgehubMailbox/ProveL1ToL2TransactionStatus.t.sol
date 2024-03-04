// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";

import {IMailbox} from "solpp/state-transition/chain-interfaces/IMailbox.sol";
import {TxStatus} from "solpp/common/Messaging.sol";

contract ProveL1ToL2TransactionStatusTest is BridgehubMailboxTest {
    // uint256 internal blockNumber;
    // bytes32 internal l2TxHash;
    // uint256 internal l2BlockNumber;
    // uint256 internal l2MessageIndex;
    // uint16 internal l2TxNumberInBlock;
    // bytes32[] internal merkleProof;
    // TxStatus internal status;
    // function setUp() public {
    //     l2TxHash = bytes32(uint256(123456789));
    //     l2BlockNumber = 3456789;
    //     l2MessageIndex = 234567890;
    //     l2TxNumberInBlock = 12345;
    //     merkleProof = new bytes32[](1);
    //     status = TxStatus.Success;
    // }
    // function test_WhenChainContractReturnsTrue() public {
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.proveL1ToL2TransactionStatus.selector,
    //             l2TxHash,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             merkleProof,
    //             status
    //         ),
    //         abi.encode(true)
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.proveL1ToL2TransactionStatus.selector,
    //             l2TxHash,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             merkleProof,
    //             status
    //         )
    //     );
    //     bool res = bridgehub.proveL1ToL2TransactionStatus(
    //         chainId,
    //         l2TxHash,
    //         l2BlockNumber,
    //         l2MessageIndex,
    //         l2TxNumberInBlock,
    //         merkleProof,
    //         status
    //     );
    //     assertEq(res, true, "L1 to L2 transaction status should be proven");
    // }
    // function test_WhenChainContractReturnsFalse() public {
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.proveL1ToL2TransactionStatus.selector,
    //             l2TxHash,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             merkleProof,
    //             status
    //         ),
    //         abi.encode(false)
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.proveL1ToL2TransactionStatus.selector,
    //             l2TxHash,
    //             l2BlockNumber,
    //             l2MessageIndex,
    //             l2TxNumberInBlock,
    //             merkleProof,
    //             status
    //         )
    //     );
    //     bool res = bridgehub.proveL1ToL2TransactionStatus(
    //         chainId,
    //         l2TxHash,
    //         l2BlockNumber,
    //         l2MessageIndex,
    //         l2TxNumberInBlock,
    //         merkleProof,
    //         status
    //     );
    //     assertEq(res, false, "L1 to L2 transaction status should not be proven");
    // }
}

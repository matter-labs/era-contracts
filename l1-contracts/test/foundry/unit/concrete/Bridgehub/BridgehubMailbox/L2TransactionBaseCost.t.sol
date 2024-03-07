// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";

import {IMailbox} from "solpp/state-transition/chain-interfaces/IMailbox.sol";

contract L2TransactionBaseCostTest is BridgehubMailboxTest {
    // uint256 internal gasPrice;
    // uint256 internal l2GasLimit;
    // uint256 internal l2GasPerPubdataByteLimit;
    // function setUp() public {
    //     gasPrice = 123456789;
    //     l2GasLimit = 234567890;
    //     l2GasPerPubdataByteLimit = 345678901;
    // }
    // function test_RevertWhen_InternalCallReverts() public {
    //     bytes memory revertMessage = "random revert";
    //     vm.mockCallRevert(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.l2TransactionBaseCost.selector,
    //             gasPrice,
    //             l2GasLimit,
    //             l2GasPerPubdataByteLimit
    //         ),
    //         revertMessage
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.l2TransactionBaseCost.selector,
    //             gasPrice,
    //             l2GasLimit,
    //             l2GasPerPubdataByteLimit
    //         )
    //     );
    //     vm.expectRevert(revertMessage);
    //     bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
    // }
    // function test_ShouldReturnReceivedCanonicalTxHash() public {
    //     uint256 expectedBaseCost = 123456789;
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.l2TransactionBaseCost.selector,
    //             gasPrice,
    //             l2GasLimit,
    //             l2GasPerPubdataByteLimit
    //         ),
    //         abi.encode(expectedBaseCost)
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(
    //             IMailbox.l2TransactionBaseCost.selector,
    //             gasPrice,
    //             l2GasLimit,
    //             l2GasPerPubdataByteLimit
    //         )
    //     );
    //     uint256 baseCost = bridgehub.l2TransactionBaseCost(chainId, gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);
    //     assertEq(baseCost, expectedBaseCost);
    // }
}

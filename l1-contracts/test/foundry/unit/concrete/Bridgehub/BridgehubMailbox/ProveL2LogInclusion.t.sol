// SPDX-License-Identifier: MIT

pragma solidity ^0.8.17;

import {BridgehubMailboxTest} from "./_BridgehubMailbox_Shared.t.sol";

import {IMailbox} from "solpp/state-transition/chain-interfaces/IMailbox.sol";
import {L2Log} from "solpp/common/Messaging.sol";

contract ProveL2LogInclusionTest is BridgehubMailboxTest {
    // uint256 internal blockNumber;
    // uint256 internal index;
    // L2Log internal l2Log;
    // bytes32[] internal proof;
    // function setUp() public {
    //     blockNumber = 3456789;
    //     index = 234567890;
    //     proof = new bytes32[](1);
    //     uint8 l2ShardId = 0;
    //     bool isService = false;
    //     uint16 txNumberInBlock = 12345;
    //     address sender = makeAddr("sender");
    //     bytes32 key = "key";
    //     bytes32 value = "value";
    //     l2Log = L2Log(l2ShardId, isService, txNumberInBlock, sender, key, value);
    // }
    // function test_WhenChainContractReturnsTrue() public {
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.proveL2LogInclusion.selector, blockNumber, index, l2Log, proof),
    //         abi.encode(true)
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.proveL2LogInclusion.selector, blockNumber, index, l2Log, proof)
    //     );
    //     bool res = bridgehub.proveL2LogInclusion(chainId, blockNumber, index, l2Log, proof);
    //     assertEq(res, true, "L2 log should be included");
    // }
    // function test_WhenChainContractReturnsFalse() public {
    //     vm.mockCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.proveL2LogInclusion.selector, blockNumber, index, l2Log, proof),
    //         abi.encode(false)
    //     );
    //     vm.expectCall(
    //         bridgehub.getStateTransition(chainId),
    //         abi.encodeWithSelector(IMailbox.proveL2LogInclusion.selector, blockNumber, index, l2Log, proof)
    //     );
    //     bool res = bridgehub.proveL2LogInclusion(chainId, blockNumber, index, l2Log, proof);
    //     assertEq(res, false, "L2 log should not be included");
    // }
}

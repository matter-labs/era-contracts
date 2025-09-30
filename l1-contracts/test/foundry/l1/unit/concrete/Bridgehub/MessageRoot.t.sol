// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {L1MessageRoot} from "contracts/bridgehub/L1MessageRoot.sol";
import {MessageRootBase} from "contracts/bridgehub/MessageRootBase.sol";
import {IBridgehubBase} from "contracts/bridgehub/IBridgehubBase.sol";
import {MessageRootNotRegistered, OnlyBridgehubOrChainAssetHandler} from "contracts/bridgehub/L1BridgehubErrors.sol";

import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant CHAIN_TREE_EMPTY_ENTRY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

// Chain tree consists of batch commitments as their leaves. We use hash of "new bytes(96)" as the hash of an empty leaf.
bytes32 constant SHARED_ROOT_TREE_EMPTY_HASH = bytes32(
    0x46700b4d40ac5c35af2c22dda2787a91eb567b06c924a8fb8ae9a05b20c08c21
);

contract MessageRootTest is Test {
    address bridgeHub;
    L1MessageRoot messageRoot;
    uint256 L1_CHAIN_ID;

    function setUp() public {
        bridgeHub = makeAddr("bridgeHub");
        L1_CHAIN_ID = 5;
        messageRoot = new L1MessageRoot(bridgeHub);
    }

    function test_init() public {
        assertEq(messageRoot.getAggregatedRoot(), (MessageHashing.chainIdLeafHash(0x00, block.chainid)));
    }

    function test_RevertWhen_addChainNotBridgeHub() public {
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        uint256 betaChainId = uint256(uint160(makeAddr("betaChainId")));

        assertFalse(messageRoot.chainRegistered(alphaChainId), "alpha chain 1");

        address chainAssetHandler = makeAddr("chainAssetHandler");
        vm.expectRevert(
            abi.encodeWithSelector(
                OnlyBridgehubOrChainAssetHandler.selector,
                address(this),
                bridgeHub,
                chainAssetHandler
            )
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        messageRoot.addNewChain(alphaChainId);

        assertFalse(messageRoot.chainRegistered(alphaChainId), "alpha chain 2");
    }

    function test_addNewChain() public {
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        uint256 betaChainId = uint256(uint160(makeAddr("betaChainId")));

        assertFalse(messageRoot.chainRegistered(alphaChainId), "alpha chain 1");
        assertFalse(messageRoot.chainRegistered(betaChainId), "beta chain 1");

        vm.prank(bridgeHub);
        vm.expectEmit(true, false, false, false);
        emit MessageRootBase.AddedChain(alphaChainId, 0);
        messageRoot.addNewChain(alphaChainId);

        assertTrue(messageRoot.chainRegistered(alphaChainId), "alpha chain 2");
        assertFalse(messageRoot.chainRegistered(betaChainId), "beta chain 2");

        assertEq(messageRoot.getChainRoot(alphaChainId), bytes32(0));
    }

    // FIXME: amend the tests as appending chain batch roots is not allowed on L1.
    // function test_RevertWhen_ChainNotRegistered() public {
    //     address alphaChainSender = makeAddr("alphaChainSender");
    //     uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
    //     vm.mockCall(
    //         bridgeHub,
    //         abi.encodeWithSelector(IBridgehub.getZKChain.selector, alphaChainId),
    //         abi.encode(alphaChainSender)
    //     );

    //     vm.prank(alphaChainSender);
    //     vm.expectRevert(MessageRootNotRegistered.selector);
    //     messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    // }

    // function test_addChainBatchRoot() public {
    //     address alphaChainSender = makeAddr("alphaChainSender");
    //     uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
    //     vm.mockCall(
    //         bridgeHub,
    //         abi.encodeWithSelector(IBridgehub.getZKChain.selector, alphaChainId),
    //         abi.encode(alphaChainSender)
    //     );

    //     vm.prank(bridgeHub);
    //     messageRoot.addNewChain(alphaChainId);

    //     vm.prank(alphaChainSender);
    //     vm.expectEmit(true, false, false, false);
    //     emit MessageRootBase.AppendedChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    //     vm.expectEmit(true, false, false, false);
    //     emit MessageRootBase.NewChainRoot(alphaChainId, bytes32(0), bytes32(0));
    //     messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    // }

    // function test_updateFullTree() public {
    //     address alphaChainSender = makeAddr("alphaChainSender");
    //     uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
    //     vm.mockCall(
    //         bridgeHub,
    //         abi.encodeWithSelector(IBridgehub.getZKChain.selector, alphaChainId),
    //         abi.encode(alphaChainSender)
    //     );

    //     vm.prank(bridgeHub);
    //     messageRoot.addNewChain(alphaChainId);

    //     vm.prank(alphaChainSender);
    //     messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));

    //     messageRoot.updateFullTree();

    //     assertEq(messageRoot.getAggregatedRoot(), 0x0ef1ac67d77f177a33449c47a8f05f0283300a81adca6f063c92c774beed140c);
    // }
}

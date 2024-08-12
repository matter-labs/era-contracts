// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {MessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";

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
    MessageRoot messageRoot;

    function setUp() public {
        bridgeHub = makeAddr("bridgeHub");
        messageRoot = new MessageRoot(IBridgehub(bridgeHub));
    }

    function test_init() public {
        assertEq(messageRoot.getAggregatedRoot(), CHAIN_TREE_EMPTY_ENTRY_HASH);
    }

    function test_RevertWhen_addChainNotBridgeHub() public {
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        uint256 betaChainId = uint256(uint160(makeAddr("betaChainId")));

        assertFalse(messageRoot.chainRegistered(alphaChainId), "alpha chain 1");

        vm.expectRevert("MR: only bridgehub");
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
        emit MessageRoot.AddedChain(alphaChainId, 0);
        messageRoot.addNewChain(alphaChainId);

        assertTrue(messageRoot.chainRegistered(alphaChainId), "alpha chain 2");
        assertFalse(messageRoot.chainRegistered(betaChainId), "beta chain 2");

        assertEq(messageRoot.getChainRoot(alphaChainId), bytes32(0));
    }

    function test_RevertWhen_ChainNotRegistered() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getHyperchain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(alphaChainSender);
        vm.expectRevert("MR: not registered");
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    }

    function test_addChainBatchRoot() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getHyperchain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(alphaChainId);

        vm.prank(alphaChainSender);
        vm.expectEmit(true, false, false, false);
        emit MessageRoot.Preimage(bytes32(0), bytes32(0));
        vm.expectEmit(true, false, false, false);
        emit MessageRoot.AppendedChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    }

    function test_updateFullTree() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getHyperchain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(alphaChainId);

        vm.prank(alphaChainSender);
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));

        messageRoot.updateFullTree();

        assertEq(messageRoot.getAggregatedRoot(), 0xbad7e1cf889e30252b8ce93820f79d50651b78587844bc1c588dea123effa4ea);
    }
}

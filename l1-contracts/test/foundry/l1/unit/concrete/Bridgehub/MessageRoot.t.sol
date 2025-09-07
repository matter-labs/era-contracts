// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {MessageRoot, IMessageRoot} from "contracts/bridgehub/MessageRoot.sol";
import {IBridgehub} from "contracts/bridgehub/IBridgehub.sol";
import {MessageRootNotRegistered, OnlyBridgehubOrChainAssetHandler, NotL2} from "contracts/bridgehub/L1BridgehubErrors.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";
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
    uint256 L1_CHAIN_ID;
    MessageRoot messageRoot;
    address assetTracker;

    function setUp() public {
        bridgeHub = makeAddr("bridgeHub");
        vm.mockCall(bridgeHub, abi.encodeWithSelector(IBridgehub.L1_CHAIN_ID.selector), abi.encode(1));
        uint256[] memory allZKChainChainIDs = new uint256[](1);
        allZKChainChainIDs[0] = 271;
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getAllZKChainChainIDs.selector),
            abi.encode(allZKChainChainIDs)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.chainTypeManager.selector),
            abi.encode(makeAddr("chainTypeManager"))
        );
        vm.mockCall(bridgeHub, abi.encodeWithSelector(IBridgehub.settlementLayer.selector), abi.encode(0));

        assetTracker = makeAddr("assetTracker");
        bridgeHub = makeAddr("bridgeHub");
        L1_CHAIN_ID = 5;
        messageRoot = new MessageRoot(IBridgehub(bridgeHub), L1_CHAIN_ID, 1);
        vm.mockCall(address(bridgeHub), abi.encodeWithSelector(Ownable.owner.selector), abi.encode(assetTracker));
        vm.prank(assetTracker);
        messageRoot.setAddresses(assetTracker);
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
            abi.encodeWithSelector(IBridgehub.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
        messageRoot.addNewChain(alphaChainId, 0);

        assertFalse(messageRoot.chainRegistered(alphaChainId), "alpha chain 2");
    }

    function test_addNewChain() public {
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        uint256 betaChainId = uint256(uint160(makeAddr("betaChainId")));

        assertFalse(messageRoot.chainRegistered(alphaChainId), "alpha chain 1");
        assertFalse(messageRoot.chainRegistered(betaChainId), "beta chain 1");

        vm.prank(bridgeHub);
        vm.expectEmit(true, false, false, false);
        emit IMessageRoot.AddedChain(alphaChainId, 0);
        messageRoot.addNewChain(alphaChainId, 0);

        assertTrue(messageRoot.chainRegistered(alphaChainId), "alpha chain 2");
        assertFalse(messageRoot.chainRegistered(betaChainId), "beta chain 2");

        assertEq(messageRoot.getChainRoot(alphaChainId), bytes32(0));
    }

    function test_RevertWhen_ChainNotRegistered() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(assetTracker);
        vm.expectRevert(MessageRootNotRegistered.selector);
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    }

    function test_RevertWhen_ChainNotL2() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, L1_CHAIN_ID),
            abi.encode(alphaChainSender)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(L1_CHAIN_ID, 0);

        vm.chainId(L1_CHAIN_ID);
        vm.prank(alphaChainSender);
        // vm.expectRevert(NotL2.selector);
        messageRoot.addChainBatchRoot(L1_CHAIN_ID, 1, bytes32(L1_CHAIN_ID));
    }

    function test_addChainBatchRoot() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(alphaChainId, 0);

        vm.prank(assetTracker);
        vm.expectEmit(true, false, false, false);
        emit IMessageRoot.AppendedChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
        vm.expectEmit(true, false, false, false);
        emit IMessageRoot.NewChainRoot(alphaChainId, bytes32(0), bytes32(0));
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    }

    function test_updateFullTree() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(alphaChainId, 0);

        vm.prank(assetTracker);
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));

        messageRoot.updateFullTree();

        assertEq(messageRoot.getAggregatedRoot(), 0x0ef1ac67d77f177a33449c47a8f05f0283300a81adca6f063c92c774beed140c);
    }

    function test_addChainBatchRootWithRealData() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = 271; //uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehub.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(alphaChainId, 0);

        vm.prank(assetTracker);
        // vm.expectEmit(true, false, false, false);
        // emit MessageRoot.Preimage(bytes32(0), bytes32(0));
        // vm.expectEmit(true, false, false, false);
        // emit MessageRoot.AppendedChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
        messageRoot.addChainBatchRoot(
            alphaChainId,
            1,
            bytes32(hex"63c4d39ce8f2410a1e65b0ad1209fe8b368928a7124bfa6e10e0d4f0786129dd")
        );
        vm.prank(assetTracker);
        messageRoot.addChainBatchRoot(
            alphaChainId,
            2,
            bytes32(hex"bcc3a5584fe0f85e968c0bae082172061e3f3a8a47ff9915adae4a3e6174fc12")
        );
        vm.prank(assetTracker);
        messageRoot.addChainBatchRoot(
            alphaChainId,
            3,
            bytes32(hex"8d1ced168691d5e8a2dc778350a2c40a2714cc7d64bff5b8da40a96c47dc5f3e")
        );
        messageRoot.getChainRoot(alphaChainId);
    }
}

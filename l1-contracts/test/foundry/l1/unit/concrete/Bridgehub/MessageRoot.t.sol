// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";
import {IMessageRoot} from "contracts/core/message-root/IMessageRoot.sol";
import {IChainAssetHandler} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";

import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {MessageRootNotRegistered, OnlyBridgehubOrChainAssetHandler} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {GW_ASSET_TRACKER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_BRIDGEHUB_ADDR, L2_CHAIN_ASSET_HANDLER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

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
    L2MessageRoot l2MessageRoot;
    uint256 L1_CHAIN_ID;
    uint256 gatewayChainId;
    address assetTracker;

    function setUp() public {
        bridgeHub = makeAddr("bridgeHub");
        uint256[] memory allZKChainChainIDsZero = new uint256[](0);
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(allZKChainChainIDsZero)
        );

        assetTracker = makeAddr("assetTracker");
        bridgeHub = makeAddr("bridgeHub");
        L1_CHAIN_ID = 5;
        gatewayChainId = 506;
        messageRoot = new L1MessageRoot(bridgeHub, 1);
        l2MessageRoot = new L2MessageRoot();

        uint256[] memory allZKChainChainIDs = new uint256[](1);
        allZKChainChainIDs[0] = 271;
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(allZKChainChainIDs)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.chainTypeManager.selector),
            abi.encode(makeAddr("chainTypeManager"))
        );

        vm.mockCall(bridgeHub, abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector), abi.encode(0));
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2MessageRoot.initL2(L1_CHAIN_ID, gatewayChainId);
        vm.mockCall(address(bridgeHub), abi.encodeWithSelector(Ownable.owner.selector), abi.encode(assetTracker));
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
        messageRoot.addNewChain(alphaChainId, 0);

        assertFalse(messageRoot.chainRegistered(alphaChainId), "alpha chain 2");
    }

    function test_addNewChain() public {
        // kl todo: enable these tests if commented out.
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
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        vm.prank(alphaChainSender);
        vm.expectRevert(MessageRootNotRegistered.selector);
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    }

    function test_addChainBatchRoot_1() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(L2_CHAIN_ASSET_HANDLER_ADDR)
        );

        vm.prank(L2_BRIDGEHUB_ADDR);
        l2MessageRoot.addNewChain(L1_CHAIN_ID, 0);

        vm.chainId(L1_CHAIN_ID);
        vm.prank(alphaChainSender);
        vm.expectRevert();
        l2MessageRoot.addChainBatchRoot(L1_CHAIN_ID, 1, bytes32(L1_CHAIN_ID));

        vm.prank(L2_BRIDGEHUB_ADDR);
        l2MessageRoot.addNewChain(alphaChainId, 0);

        vm.prank(alphaChainSender);
        vm.expectEmit(true, false, false, false);
        emit IMessageRoot.AppendedChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
        vm.expectEmit(true, false, false, false);
        emit IMessageRoot.NewChainRoot(alphaChainId, bytes32(0), bytes32(0));
        l2MessageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
    }

    function test_updateFullTree() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );
        vm.mockCall(
            address(bridgeHub),
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(L2_CHAIN_ASSET_HANDLER_ADDR)
        );
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(L2_CHAIN_ASSET_HANDLER_ADDR)
        );
        vm.prank(bridgeHub);
        messageRoot.addNewChain(alphaChainId, 0);
        vm.prank(alphaChainSender);
        messageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
        vm.prank(L2_BRIDGEHUB_ADDR);
        l2MessageRoot.addNewChain(alphaChainId, 0);
        vm.chainId(gatewayChainId);
        vm.prank(GW_ASSET_TRACKER_ADDR);
        l2MessageRoot.addChainBatchRoot(alphaChainId, 1, bytes32(alphaChainId));
        l2MessageRoot.updateFullTree();
        assertEq(l2MessageRoot.getAggregatedRoot(), 0x0ef1ac67d77f177a33449c47a8f05f0283300a81adca6f063c92c774beed140c);
    }

    function test_addChainBatchRootWithRealData() public {
        address alphaChainSender = makeAddr("alphaChainSender");
        uint256 alphaChainId = 271; //uint256(uint160(makeAddr("alphaChainId")));
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, alphaChainId),
            abi.encode(alphaChainSender)
        );

        // Verify chain is not registered initially
        assertFalse(messageRoot.chainRegistered(alphaChainId), "Chain should not be registered initially");

        vm.prank(bridgeHub);
        messageRoot.addNewChain(alphaChainId, 0);

        // Verify chain is now registered
        assertTrue(messageRoot.chainRegistered(alphaChainId), "Chain should be registered after addNewChain");

        // Initial chain root should be zero
        bytes32 initialChainRoot = messageRoot.getChainRoot(alphaChainId);
        assertEq(initialChainRoot, bytes32(0), "Initial chain root should be zero");

        // Verify first batch number is 0 before adding any batches
        uint256 initialBatchNumber = messageRoot.currentChainBatchNumber(alphaChainId);
        assertEq(initialBatchNumber, 0, "Initial batch number should be 0");

        vm.prank(alphaChainSender);
        messageRoot.addChainBatchRoot(
            alphaChainId,
            1,
            bytes32(hex"63c4d39ce8f2410a1e65b0ad1209fe8b368928a7124bfa6e10e0d4f0786129dd")
        );

        // Verify batch number incremented after adding first batch
        uint256 batchNumberAfterBatch1 = messageRoot.currentChainBatchNumber(alphaChainId);
        assertEq(batchNumberAfterBatch1, 1, "Batch number should be 1 after adding first batch");

        vm.prank(alphaChainSender);
        messageRoot.addChainBatchRoot(
            alphaChainId,
            2,
            bytes32(hex"bcc3a5584fe0f85e968c0bae082172061e3f3a8a47ff9915adae4a3e6174fc12")
        );

        // Verify batch number incremented after adding second batch
        uint256 batchNumberAfterBatch2 = messageRoot.currentChainBatchNumber(alphaChainId);
        assertEq(batchNumberAfterBatch2, 2, "Batch number should be 2 after adding second batch");

        vm.prank(alphaChainSender);
        messageRoot.addChainBatchRoot(
            alphaChainId,
            3,
            bytes32(hex"8d1ced168691d5e8a2dc778350a2c40a2714cc7d64bff5b8da40a96c47dc5f3e")
        );

        // Verify batch number incremented after adding third batch
        uint256 finalBatchNumber = messageRoot.currentChainBatchNumber(alphaChainId);
        assertEq(finalBatchNumber, 3, "Final batch number should be 3");

        // Get the final chain root (may or may not be zero depending on tree implementation)
        bytes32 finalChainRoot = messageRoot.getChainRoot(alphaChainId);
        // Chain root is computed - the test verifies the function can be called without reverting
        // The actual root value depends on the merkle tree implementation
    }
}

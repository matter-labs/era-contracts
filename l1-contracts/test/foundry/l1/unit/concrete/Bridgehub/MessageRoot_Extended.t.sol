// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MigrationTestBase} from "test/foundry/l1/integration/unit-migration/_SharedMigrationBase.t.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {L1MessageRoot} from "contracts/core/message-root/L1MessageRoot.sol";
import {L2MessageRoot} from "contracts/core/message-root/L2MessageRoot.sol";
import {IMessageRootBase} from "contracts/core/message-root/IMessageRoot.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {
    ChainExists,
    MessageRootNotRegistered,
    OnlyChain,
    OnlyGateway,
    OnlyOnSettlementLayer,
    TotalBatchesExecutedZero,
    V31UpgradeChainBatchNumberNotSet
} from "contracts/core/bridgehub/L1BridgehubErrors.sol";

import {
    GW_ASSET_TRACKER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {ProofData} from "contracts/common/Messaging.sol";

import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";

import {L1Bridgehub} from "contracts/core/bridgehub/L1Bridgehub.sol";

contract MessageRoot_Extended_Test is MigrationTestBase {
    address bridgeHub;
    uint256 L1_CHAIN_ID;
    uint256 gatewayChainId;
    L1MessageRoot messageRoot;
    L2MessageRoot l2MessageRoot;
    address assetTracker;
    address chainAssetHandler;

    function setUp() public virtual override {
        // Deploy real ecosystem — real bridgehub answers queries without mocks
        _deployIntegrationBase();

        bridgeHub = address(addresses.bridgehub);
        chainAssetHandler = addresses.bridgehub.chainAssetHandler();
        assetTracker = makeAddr("assetTracker");
        L1_CHAIN_ID = 1;
        gatewayChainId = 506;

        // L1MessageRoot rejects construction when bridgehub has registered chains.
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getAllZKChainChainIDs.selector),
            abi.encode(new uint256[](0))
        );

        messageRoot = L1MessageRoot(
            address(
                new TransparentUpgradeableProxy(
                    address(new L1MessageRoot(bridgeHub, gatewayChainId, chainAssetHandler)),
                    address(uint160(1)),
                    abi.encodeCall(L1MessageRoot.initialize, ())
                )
            )
        );
        l2MessageRoot = new L2MessageRoot();

        // Real bridgehub answers: L1_CHAIN_ID, chainAssetHandler, owner,
        // chainTypeManager, settlementLayer — no mocks needed

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        l2MessageRoot.initL2(L1_CHAIN_ID, gatewayChainId);
    }

    function test_ChainRegistered_CurrentChain() public {
        // Test that current chain is always registered
        assertTrue(messageRoot.chainRegistered(block.chainid));
    }

    function test_ChainRegistered_UnregisteredChain() public {
        uint256 unregisteredChainId = 999;
        assertFalse(messageRoot.chainRegistered(unregisteredChainId));
    }

    function test_AddNewChain_ChainExists() public {
        uint256 chainId = 271;

        // Add chain first time
        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId, 0);

        // Try to add same chain again
        vm.prank(bridgeHub);
        vm.expectRevert(ChainExists.selector);
        messageRoot.addNewChain(chainId, 0);
    }

    function test_AddNewChain_FromChainAssetHandler() public {
        uint256 chainId = 271;

        vm.prank(chainAssetHandler);
        vm.expectEmit(true, false, false, false);
        emit IMessageRootBase.AddedChain(chainId, 0);
        messageRoot.addNewChain(chainId, 0);

        assertTrue(messageRoot.chainRegistered(chainId));
    }

    function test_GetChainRoot_ChainNotRegistered() public {
        uint256 unregisteredChainId = 999;
        vm.expectRevert(MessageRootNotRegistered.selector);
        messageRoot.getChainRoot(unregisteredChainId);
    }

    function test_GetAggregatedRoot_WithChains() public {
        uint256 chainId = 271;

        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId, 0);

        // Should return the shared tree root
        bytes32 root = messageRoot.getAggregatedRoot();
        assertTrue(root != bytes32(0));
    }

    function test_InitializeL1V31Upgrade_NotL1() public {
        vm.chainId(2); // Set to non-L1 chain

        vm.expectRevert("Initializable: contract is already initialized");
        messageRoot.initializeL1V31Upgrade();
    }

    function test_SaveV31UpgradeChainBatchNumber_NotChain() public {
        uint256 chainId = 271;
        address wrongSender = makeAddr("wrongSender");

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(makeAddr("correctChain"))
        );

        vm.expectRevert(abi.encodeWithSelector(OnlyChain.selector, wrongSender, makeAddr("correctChain")));
        vm.prank(wrongSender);
        messageRoot.saveV31UpgradeChainBatchNumber(chainId);
    }

    function test_SaveV31UpgradeChainBatchNumber_NotOnSettlementLayer() public {
        uint256 chainId = 271;
        address chainSender = makeAddr("chainSender");

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(chainSender)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, chainId),
            abi.encode(2) // Different settlement layer
        );

        vm.expectRevert(OnlyOnSettlementLayer.selector);
        vm.prank(chainSender);
        messageRoot.saveV31UpgradeChainBatchNumber(chainId);
    }

    function test_SaveV31UpgradeChainBatchNumber_TotalBatchesExecutedZero() public {
        uint256 chainId = 271;
        address chainSender = makeAddr("chainSender");

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(chainSender)
        );
        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.settlementLayer.selector, chainId),
            abi.encode(block.chainid)
        );

        // Mock getTotalBatchesExecuted to return 0
        vm.mockCall(chainSender, abi.encodeWithSelector(IGetters.getTotalBatchesExecuted.selector), abi.encode(0));

        vm.expectRevert(TotalBatchesExecutedZero.selector);
        vm.prank(chainSender);
        messageRoot.saveV31UpgradeChainBatchNumber(chainId);
    }

    function test_setMigratingChainBatchNumber_Success() public {
        uint256 chainId = 271;
        uint256 batchNumber = 1;

        vm.prank(bridgeHub);
        messageRoot.setMigratingChainBatchNumber(chainId, batchNumber);

        assertEq(messageRoot.currentChainBatchNumber(chainId), batchNumber);
    }

    function test_GetProofData() public {
        uint256 chainId = 271;
        uint256 batchNumber = 1;
        uint256 leafProofMask = 1;
        bytes32 leaf = keccak256("leaf");
        bytes32[] memory proof = new bytes32[](1);
        proof[0] = keccak256("proof");

        ProofData memory result = messageRoot.getProofData(chainId, batchNumber, leafProofMask, leaf, proof);

        // Verify the result is not empty
        assertTrue(result.settlementLayerChainId != 0 || result.batchSettlementRoot != bytes32(0));
    }

    function test_ChainCount() public {
        uint256 initialCount = messageRoot.chainCount();
        assertEq(initialCount, 1); // Current chain is always registered

        uint256 chainId = 271;
        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId, 0);

        uint256 newCount = messageRoot.chainCount();
        assertEq(newCount, 2);
    }

    function test_ChainIndex() public {
        uint256 chainId = 271;

        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId, 0);

        uint256 index = messageRoot.chainIndex(chainId);
        assertEq(index, 1);

        uint256 chainIdFromIndex = messageRoot.chainIndexToId(1);
        assertEq(chainIdFromIndex, chainId);
    }

    function test_CurrentChainBatchNumber() public {
        uint256 chainId = 271;
        uint256 startingBatchNumber = 5;

        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId, startingBatchNumber);

        uint256 currentBatch = messageRoot.currentChainBatchNumber(chainId);
        assertEq(currentBatch, startingBatchNumber);
    }

    function test_V31UpgradeChainBatchNumber() public {
        uint256 chainId = 271;
        uint256 v31UpgradeBatchNumber = 0;

        vm.prank(bridgeHub);
        messageRoot.setMigratingChainBatchNumber(chainId, 1);

        uint256 v31Batch = messageRoot.v31UpgradeChainBatchNumber(chainId);
        assertEq(v31Batch, v31UpgradeBatchNumber);
    }

    function test_AddChainBatchRoot_Success() public {
        uint256 chainId = 271;
        address chainSender = makeAddr("chainSender");
        bytes32 batchRoot = keccak256("batchRoot");

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(chainSender)
        );

        // Mock the getSemverProtocolVersion call
        vm.mockCall(
            chainSender,
            abi.encodeWithSelector(IGetters.getSemverProtocolVersion.selector),
            abi.encode(0, 29, 0) // major, minor, patch
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId, 0);

        // Successfully add batch root
        vm.prank(chainSender);
        messageRoot.addChainBatchRoot(chainId, 1, batchRoot);

        // Verify batch root is stored
        assertEq(messageRoot.chainBatchRoots(chainId, 1), batchRoot);
        assertEq(messageRoot.currentChainBatchNumber(chainId), 1);
    }

    function test_AddChainBatchRoot_ConsecutiveBatchNumber() public {
        uint256 chainId = 271;
        address chainSender = makeAddr("chainSender");
        bytes32 batchRoot1 = keccak256("batchRoot1");
        bytes32 batchRoot2 = keccak256("batchRoot2");

        vm.mockCall(
            bridgeHub,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(chainSender)
        );

        // Mock the getSemverProtocolVersion call
        vm.mockCall(
            chainSender,
            abi.encodeWithSelector(IGetters.getSemverProtocolVersion.selector),
            abi.encode(0, 29, 0) // major, minor, patch
        );

        vm.prank(bridgeHub);
        messageRoot.addNewChain(chainId, 0);

        // Add first batch root
        vm.prank(chainSender);
        messageRoot.addChainBatchRoot(chainId, 1, batchRoot1);

        // Add second batch root
        vm.prank(chainSender);
        messageRoot.addChainBatchRoot(chainId, 2, batchRoot2);

        // Verify both batch roots are stored
        assertEq(messageRoot.chainBatchRoots(chainId, 1), batchRoot1);
        assertEq(messageRoot.chainBatchRoots(chainId, 2), batchRoot2);
        assertEq(messageRoot.currentChainBatchNumber(chainId), 2);
    }

    function test_HistoricalRoot() public {
        uint256 chainId = 271;
        address chainSender = makeAddr("chainSender");

        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, chainId),
            abi.encode(chainSender)
        );

        // Mock the getSemverProtocolVersion call
        vm.mockCall(
            chainSender,
            abi.encodeWithSelector(IGetters.getSemverProtocolVersion.selector),
            abi.encode(0, 29, 0) // major, minor, patch
        );

        vm.prank(L2_BRIDGEHUB_ADDR);
        l2MessageRoot.addNewChain(chainId, 0);

        // With per-block logId: initL2 + addNewChain(chainId) both happen in the same block, so
        // interopRootLogId is incremented only once (for that block).
        uint256 countBefore = l2MessageRoot.interopRootLogId();
        assertEq(countBefore, 1, "interopRootLogId should be 1 (single block so far)");

        // Roll to a new block so the next emission increments the counter.
        vm.roll(block.number + 1);

        // Add a batch root
        vm.prank(GW_ASSET_TRACKER_ADDR);
        l2MessageRoot.addChainBatchRoot(chainId, 1, keccak256("batchRoot"));

        // Verify interopRootLogId incremented once for the new block
        assertEq(
            l2MessageRoot.interopRootLogId(),
            countBefore + 1,
            "interopRootLogId should increment by 1 when block advances"
        );

        // Check that historical root is set
        bytes32 historicalRoot = l2MessageRoot.historicalRoot(block.number);
        assertTrue(historicalRoot != bytes32(0));
    }

    function test_L1_CHAIN_ID() public view {
        uint256 chainId = messageRoot.L1_CHAIN_ID();
        assertEq(chainId, block.chainid);
    }

    function test_ERA_GATEWAY_CHAIN_ID() public view {
        uint256 eraGatewayId = messageRoot.ERA_GATEWAY_CHAIN_ID();
        assertEq(eraGatewayId, gatewayChainId);
    }

    function test_BRIDGE_HUB() public view {
        address bridge = messageRoot.BRIDGE_HUB();
        assertEq(bridge, bridgeHub);
    }

    function test_ChainBatchRoots() public view {
        uint256 chainId = 999;
        uint256 batchNumber = 1;
        // Should return zero for unset chain batch roots
        bytes32 root = messageRoot.chainBatchRoots(chainId, batchNumber);
        assertEq(root, bytes32(0));
    }

    function test_GetAggregatedRoot_EmptyTree() public view {
        // Before any chains are added (but current chain is always registered)
        // the chainCount is 1 (the current chain)
        bytes32 root = messageRoot.getAggregatedRoot();
        assertTrue(root != bytes32(0));
    }

    function test_ChainIndexToId_Mapping() public view {
        // Current chain is at index 0
        uint256 chainAtIndex0 = messageRoot.chainIndexToId(0);
        assertEq(chainAtIndex0, block.chainid);
    }
}

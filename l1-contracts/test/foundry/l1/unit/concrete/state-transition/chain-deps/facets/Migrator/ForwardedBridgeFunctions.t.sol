// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {MigratorTest} from "./_Migrator_Shared.t.sol";
import {Unauthorized, NotAZKChain} from "contracts/common/L1ContractErrors.sol";
import {NotL1, AlreadyMigrated, NotChainAdmin, NotEraChain, NotAllBatchesExecuted, ProtocolVersionNotUpToDate, OutdatedProtocolVersion, ExecutedIsNotConsistentWithVerified, VerifiedIsNotConsistentWithCommitted, InvalidNumberOfBatchHashes, NotMigrated, NotHistoricalRoot, ContractNotDeployed} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {ZKChainCommitment} from "contracts/common/Config.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {PriorityTreeCommitment} from "contracts/state-transition/libraries/PriorityTree.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS, CHAIN_MIGRATION_TIME_WINDOW_START_MAINNET, CHAIN_MIGRATION_TIME_WINDOW_END_MAINNET} from "contracts/common/Config.sol";

contract ForwardedBridgeFunctionsTest is MigratorTest {
    address chainAssetHandler;
    address admin;

    function setUp() public override {
        super.setUp();
        chainAssetHandler = makeAddr("chainAssetHandler");
        admin = utilsFacet.util_getAdmin();

        // Mock bridgehub to return chainAssetHandler
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainAssetHandler.selector),
            abi.encode(chainAssetHandler)
        );
    }

    /*//////////////////////////////////////////////////////////////
                        forwardedBridgeBurn Tests
    //////////////////////////////////////////////////////////////*/

    function test_forwardedBridgeBurn_RevertWhen_NotChainAssetHandler() public {
        address notHandler = makeAddr("notHandler");
        bytes memory data = abi.encode(uint256(1));

        vm.prank(notHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notHandler));
        migratorFacet.forwardedBridgeBurn(address(0), admin, data);
    }

    function test_forwardedBridgeBurn_RevertWhen_AlreadyMigrated() public {
        bytes memory data = abi.encode(uint256(1));
        // Set settlementLayer to non-zero to simulate already migrated state
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.prank(chainAssetHandler);
        vm.expectRevert(AlreadyMigrated.selector);
        migratorFacet.forwardedBridgeBurn(address(0), admin, data);
    }

    function test_forwardedBridgeBurn_RevertWhen_NotChainAdmin() public {
        bytes memory data = abi.encode(uint256(1));
        address notAdmin = makeAddr("notAdmin");

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(NotChainAdmin.selector, notAdmin, admin));
        migratorFacet.forwardedBridgeBurn(address(0), notAdmin, data);
    }

    function _setupPausedDepositsState() internal {
        // Set pausedDepositsTimestamp to allow migration (must be in valid time window)
        // The check is: timestamp + CHAIN_MIGRATION_TIME_WINDOW_START < block.timestamp &&
        //               block.timestamp < timestamp + CHAIN_MIGRATION_TIME_WINDOW_END
        // Warp to a sufficiently large timestamp to avoid underflow
        vm.warp(CHAIN_MIGRATION_TIME_WINDOW_END_MAINNET + 10);
        uint256 timestamp = block.timestamp - CHAIN_MIGRATION_TIME_WINDOW_START_MAINNET - 1;
        utilsFacet.util_setPausedDepositsTimestamp(timestamp);
    }

    function test_forwardedBridgeBurn_RevertWhen_NotAZKChain() public {
        _setupPausedDepositsState();

        // Create a fake settlement layer that is not registered as a ZKChain
        address fakeSettlementLayer = makeAddr("fakeSettlementLayer");
        uint256 fakeChainId = 999;

        // Mock the settlement layer to return a fake chain ID
        vm.mockCall(fakeSettlementLayer, abi.encodeWithSelector(IGetters.getChainId.selector), abi.encode(fakeChainId));

        // Mock bridgehub to return a different address for that chain ID
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, fakeChainId),
            abi.encode(makeAddr("differentZKChain"))
        );

        bytes memory data = abi.encode(utilsFacet.util_getProtocolVersion());

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(NotAZKChain.selector, fakeSettlementLayer));
        migratorFacet.forwardedBridgeBurn(fakeSettlementLayer, admin, data);
    }

    function test_forwardedBridgeBurn_RevertWhen_NotEraChain() public {
        _setupPausedDepositsState();

        // Create a settlement layer that is a valid ZKChain but with different CTM
        address settlementLayer = makeAddr("settlementLayer");
        uint256 settlementChainId = 999;
        address differentCtm = makeAddr("differentCtm");

        // Mock the settlement layer to return a chain ID
        vm.mockCall(
            settlementLayer,
            abi.encodeWithSelector(IGetters.getChainId.selector),
            abi.encode(settlementChainId)
        );

        // Mock bridgehub to return the same address (valid ZKChain)
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.getZKChain.selector, settlementChainId),
            abi.encode(settlementLayer)
        );

        // Mock bridgehub to return a different CTM for that chain
        vm.mockCall(
            address(dummyBridgehub),
            abi.encodeWithSelector(IBridgehubBase.chainTypeManager.selector, settlementChainId),
            abi.encode(differentCtm)
        );

        bytes memory data = abi.encode(utilsFacet.util_getProtocolVersion());

        vm.prank(chainAssetHandler);
        vm.expectRevert(NotEraChain.selector);
        migratorFacet.forwardedBridgeBurn(settlementLayer, admin, data);
    }

    function test_forwardedBridgeBurn_RevertWhen_ProtocolVersionNotUpToDate() public {
        _setupPausedDepositsState();

        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        uint256 differentVersion = currentProtocolVersion + 1;
        bytes memory data = abi.encode(differentVersion);

        vm.prank(chainAssetHandler);
        vm.expectRevert(
            abi.encodeWithSelector(ProtocolVersionNotUpToDate.selector, currentProtocolVersion, differentVersion)
        );
        migratorFacet.forwardedBridgeBurn(L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS, admin, data);
    }

    function test_forwardedBridgeBurn_RevertWhen_NotAllBatchesExecuted() public {
        _setupPausedDepositsState();

        // Set committed != executed
        utilsFacet.util_setTotalBatchesCommitted(10);
        utilsFacet.util_setTotalBatchesExecuted(5);

        bytes memory data = abi.encode(utilsFacet.util_getProtocolVersion());

        vm.prank(chainAssetHandler);
        vm.expectRevert(NotAllBatchesExecuted.selector);
        migratorFacet.forwardedBridgeBurn(L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS, admin, data);
    }

    /*//////////////////////////////////////////////////////////////
                        forwardedBridgeMint Tests
    //////////////////////////////////////////////////////////////*/

    function test_forwardedBridgeMint_RevertWhen_NotChainAssetHandler() public {
        address notHandler = makeAddr("notHandler");
        bytes memory data = "";

        vm.prank(notHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notHandler));
        migratorFacet.forwardedBridgeMint(data, false);
    }

    function test_forwardedBridgeMint_RevertWhen_OutdatedProtocolVersion() public {
        // Setup: create a commitment with a different protocol version
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        uint256 differentVersion = currentProtocolVersion + 1;

        // Mock CTM to return a different protocol version
        address ctm = utilsFacet.util_getChainTypeManager();
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(differentVersion)
        );

        PriorityTreeCommitment memory priorityTreeCommitment = PriorityTreeCommitment({
            nextLeafIndex: 0,
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesExecuted: 0,
            totalBatchesVerified: 0,
            totalBatchesCommitted: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            l2SystemContractsUpgradeBatchNumber: 0,
            batchHashes: new bytes32[](1),
            priorityTree: priorityTreeCommitment,
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(
            abi.encodeWithSelector(OutdatedProtocolVersion.selector, differentVersion, currentProtocolVersion)
        );
        migratorFacet.forwardedBridgeMint(data, false);
    }

    function test_forwardedBridgeMint_RevertWhen_ExecutedIsNotConsistentWithVerified() public {
        address ctm = utilsFacet.util_getChainTypeManager();
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(currentProtocolVersion)
        );

        PriorityTreeCommitment memory priorityTreeCommitment = PriorityTreeCommitment({
            nextLeafIndex: 0,
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        // Create commitment where executed > verified
        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesExecuted: 8, // Greater than verified
            totalBatchesVerified: 5,
            totalBatchesCommitted: 10,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            l2SystemContractsUpgradeBatchNumber: 0,
            batchHashes: new bytes32[](1),
            priorityTree: priorityTreeCommitment,
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(ExecutedIsNotConsistentWithVerified.selector, 8, 5));
        migratorFacet.forwardedBridgeMint(data, false);
    }

    function test_forwardedBridgeMint_RevertWhen_VerifiedIsNotConsistentWithCommitted() public {
        address ctm = utilsFacet.util_getChainTypeManager();
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(currentProtocolVersion)
        );

        PriorityTreeCommitment memory priorityTreeCommitment = PriorityTreeCommitment({
            nextLeafIndex: 0,
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        // Create commitment where verified > committed
        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesExecuted: 2,
            totalBatchesVerified: 8, // Greater than committed
            totalBatchesCommitted: 5,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            l2SystemContractsUpgradeBatchNumber: 0,
            batchHashes: new bytes32[](1),
            priorityTree: priorityTreeCommitment,
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(VerifiedIsNotConsistentWithCommitted.selector, 8, 5));
        migratorFacet.forwardedBridgeMint(data, false);
    }

    function test_forwardedBridgeMint_RevertWhen_InvalidNumberOfBatchHashes() public {
        address ctm = utilsFacet.util_getChainTypeManager();
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(currentProtocolVersion)
        );

        PriorityTreeCommitment memory priorityTreeCommitment = PriorityTreeCommitment({
            nextLeafIndex: 0,
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        // committed=10, executed=5, so we need 10-5+1 = 6 batch hashes
        // But we provide only 2
        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesExecuted: 5,
            totalBatchesVerified: 8,
            totalBatchesCommitted: 10,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            l2SystemContractsUpgradeBatchNumber: 0,
            batchHashes: new bytes32[](2), // Wrong number
            priorityTree: priorityTreeCommitment,
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(InvalidNumberOfBatchHashes.selector, 2, 6));
        migratorFacet.forwardedBridgeMint(data, false);
    }

    /*//////////////////////////////////////////////////////////////
                forwardedBridgeConfirmTransferResult Tests
    //////////////////////////////////////////////////////////////*/

    function test_forwardedBridgeConfirmTransferResult_RevertWhen_NotChainAssetHandler() public {
        address notHandler = makeAddr("notHandler");
        bytes memory data = abi.encode(uint256(1));

        vm.prank(notHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notHandler));
        migratorFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Failure, bytes32(0), address(0), data);
    }

    function test_forwardedBridgeConfirmTransferResult_Success_ReturnsEarlyOnSuccess() public {
        bytes memory data = abi.encode(uint256(1));

        // Should return early without checking migration state when TxStatus.Success
        vm.prank(chainAssetHandler);
        migratorFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Success, bytes32(0), address(0), data);
    }

    function test_forwardedBridgeConfirmTransferResult_RevertWhen_NotMigrated() public {
        bytes memory data = abi.encode(utilsFacet.util_getProtocolVersion());

        // Settlement layer is address(0) which means not migrated
        vm.prank(chainAssetHandler);
        vm.expectRevert(NotMigrated.selector);
        migratorFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Failure, bytes32(0), address(0), data);
    }

    function test_forwardedBridgeConfirmTransferResult_RevertWhen_OutdatedProtocolVersion() public {
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        uint256 differentVersion = currentProtocolVersion + 1;
        bytes memory data = abi.encode(differentVersion);

        // Set settlement layer to non-zero to simulate migrated state
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.prank(chainAssetHandler);
        vm.expectRevert(
            abi.encodeWithSelector(OutdatedProtocolVersion.selector, differentVersion, currentProtocolVersion)
        );
        migratorFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Failure, bytes32(0), address(0), data);
    }

    /*//////////////////////////////////////////////////////////////
                    forwardedBridgeMint L1-specific Tests
    //////////////////////////////////////////////////////////////*/

    function test_forwardedBridgeMint_RevertWhen_NotHistoricalRoot_OnL1() public {
        // Setup: on L1, check historical root validation
        address ctm = utilsFacet.util_getChainTypeManager();
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(currentProtocolVersion)
        );

        // Create a priority tree commitment with a side that's NOT a historical root
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = bytes32(uint256(12345)); // Random non-historical root

        PriorityTreeCommitment memory priorityTreeCommitment = PriorityTreeCommitment({
            nextLeafIndex: 0,
            startIndex: 0,
            unprocessedIndex: 0,
            sides: sides
        });

        // Create valid commitment (executed=verified=committed=0, so we need 1 batch hash)
        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesExecuted: 0,
            totalBatchesVerified: 0,
            totalBatchesCommitted: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            l2SystemContractsUpgradeBatchNumber: 0,
            batchHashes: new bytes32[](1),
            priorityTree: priorityTreeCommitment,
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        // On L1, should revert with NotHistoricalRoot
        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(NotHistoricalRoot.selector, sides[0]));
        migratorFacet.forwardedBridgeMint(data, true);
    }

    function test_forwardedBridgeMint_RevertWhen_NotMigrated_OnL1_ContractAlreadyDeployed() public {
        // Setup: on L1, with _contractAlreadyDeployed=true but settlementLayer=address(0)
        address ctm = utilsFacet.util_getChainTypeManager();
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(currentProtocolVersion)
        );

        // Ensure settlement layer is address(0) (default)
        assertEq(utilsFacet.util_getSettlementLayer(), address(0));

        // We need to make the historical root check pass first
        // Set up a historical root in storage
        bytes32 historicalRoot = bytes32(uint256(0x123456));

        // The priorityTree is at slot 51 in ZKChainStorage
        // Looking at PriorityTree.sol:
        // struct Tree { uint256 startIndex; uint256 unprocessedIndex; mapping(bytes32 => bool) historicalRoots; DynamicIncrementalMerkle.Bytes32PushTree tree; }
        // The priorityTree storage layout:
        // - startIndex: slot 51
        // - unprocessedIndex: slot 52
        // - historicalRoots: slot 53 (mapping base)
        // - tree._nextLeafIndex: slot 54
        // - tree._sides length: slot 55
        // So historicalRoots[key] = keccak256(abi.encode(key, 53))

        bytes32 mappingSlot = keccak256(abi.encode(historicalRoot, uint256(53)));
        vm.store(address(migratorFacet), mappingSlot, bytes32(uint256(1)));

        bytes32[] memory sides = new bytes32[](1);
        sides[0] = historicalRoot;

        PriorityTreeCommitment memory priorityTreeCommitment = PriorityTreeCommitment({
            nextLeafIndex: 0,
            startIndex: 0,
            unprocessedIndex: 0,
            sides: sides
        });

        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesExecuted: 0,
            totalBatchesVerified: 0,
            totalBatchesCommitted: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            l2SystemContractsUpgradeBatchNumber: 0,
            batchHashes: new bytes32[](1),
            priorityTree: priorityTreeCommitment,
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        // On L1, with _contractAlreadyDeployed=true but settlementLayer=address(0), should revert
        vm.prank(chainAssetHandler);
        vm.expectRevert(NotMigrated.selector);
        migratorFacet.forwardedBridgeMint(data, true);
    }

    function test_forwardedBridgeMint_RevertWhen_NotMigrated_OnGateway_ContractAlreadyDeployed() public {
        // Switch to Gateway chain (not L1)
        uint256 gatewayChainId = 505;
        vm.chainId(gatewayChainId);

        address ctm = utilsFacet.util_getChainTypeManager();
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        vm.mockCall(
            ctm,
            abi.encodeWithSelector(IChainTypeManager.protocolVersion.selector),
            abi.encode(currentProtocolVersion)
        );

        // Ensure settlement layer is address(0) (not migrated)
        assertEq(utilsFacet.util_getSettlementLayer(), address(0));

        PriorityTreeCommitment memory priorityTreeCommitment = PriorityTreeCommitment({
            nextLeafIndex: 0,
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesExecuted: 0,
            totalBatchesVerified: 0,
            totalBatchesCommitted: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            l2SystemContractsUpgradeBatchNumber: 0,
            batchHashes: new bytes32[](1),
            priorityTree: priorityTreeCommitment,
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        // On Gateway, with _contractAlreadyDeployed=true but settlementLayer=address(0), should revert with NotMigrated
        vm.prank(chainAssetHandler);
        vm.expectRevert(NotMigrated.selector);
        migratorFacet.forwardedBridgeMint(data, true);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}

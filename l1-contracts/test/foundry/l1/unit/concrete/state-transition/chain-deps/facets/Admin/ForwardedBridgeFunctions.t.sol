// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AdminTest} from "./_Admin_Shared.t.sol";
import {Unauthorized, NotAZKChain} from "contracts/common/L1ContractErrors.sol";
import {NotL1, AlreadyMigrated, NotChainAdmin, NotEraChain, NotAllBatchesExecuted, ProtocolVersionNotUpToDate, OutdatedProtocolVersion, ExecutedIsNotConsistentWithVerified, VerifiedIsNotConsistentWithCommitted, InvalidNumberOfBatchHashes, NotMigrated, NotHistoricalRoot, ContractNotDeployed} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {IAdmin, ZKChainCommitment} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {TxStatus} from "contracts/common/Messaging.sol";
import {PriorityTreeCommitment} from "contracts/state-transition/libraries/PriorityTree.sol";
import {IBridgehubBase} from "contracts/core/bridgehub/IBridgehubBase.sol";
import {IL1Bridgehub} from "contracts/core/bridgehub/IL1Bridgehub.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IZKChain} from "contracts/state-transition/chain-interfaces/IZKChain.sol";
import {L1_SETTLEMENT_LAYER_VIRTUAL_ADDRESS} from "contracts/common/Config.sol";

contract ForwardedBridgeFunctionsTest is AdminTest {
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
        adminFacet.forwardedBridgeBurn(address(0), admin, data);
    }

    function test_forwardedBridgeBurn_RevertWhen_AlreadyMigrated() public {
        bytes memory data = abi.encode(uint256(1));
        // Set settlementLayer to non-zero to simulate already migrated state
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.prank(chainAssetHandler);
        vm.expectRevert(AlreadyMigrated.selector);
        adminFacet.forwardedBridgeBurn(address(0), admin, data);
    }

    function test_forwardedBridgeBurn_RevertWhen_NotChainAdmin() public {
        bytes memory data = abi.encode(uint256(1));
        address notAdmin = makeAddr("notAdmin");

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(NotChainAdmin.selector, notAdmin, admin));
        adminFacet.forwardedBridgeBurn(address(0), notAdmin, data);
    }

    /*//////////////////////////////////////////////////////////////
                        forwardedBridgeMint Tests
    //////////////////////////////////////////////////////////////*/

    function test_forwardedBridgeMint_RevertWhen_NotChainAssetHandler() public {
        address notHandler = makeAddr("notHandler");
        bytes memory data = "";

        vm.prank(notHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notHandler));
        adminFacet.forwardedBridgeMint(data, false);
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
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesCommitted: 0,
            totalBatchesVerified: 0,
            totalBatchesExecuted: 0,
            l2SystemContractsUpgradeBatchNumber: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            priorityTree: priorityTreeCommitment,
            batchHashes: new bytes32[](1),
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(OutdatedProtocolVersion.selector, differentVersion, currentProtocolVersion));
        adminFacet.forwardedBridgeMint(data, false);
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
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        // Create commitment where executed > verified
        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesCommitted: 10,
            totalBatchesVerified: 5,
            totalBatchesExecuted: 8, // Greater than verified
            l2SystemContractsUpgradeBatchNumber: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            priorityTree: priorityTreeCommitment,
            batchHashes: new bytes32[](1),
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(ExecutedIsNotConsistentWithVerified.selector, 8, 5));
        adminFacet.forwardedBridgeMint(data, false);
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
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        // Create commitment where verified > committed
        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesCommitted: 5,
            totalBatchesVerified: 8, // Greater than committed
            totalBatchesExecuted: 2,
            l2SystemContractsUpgradeBatchNumber: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            priorityTree: priorityTreeCommitment,
            batchHashes: new bytes32[](1),
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(VerifiedIsNotConsistentWithCommitted.selector, 8, 5));
        adminFacet.forwardedBridgeMint(data, false);
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
            startIndex: 0,
            unprocessedIndex: 0,
            sides: new bytes32[](0)
        });

        // committed=10, executed=5, so we need 10-5+1 = 6 batch hashes
        // But we provide only 2
        ZKChainCommitment memory commitment = ZKChainCommitment({
            totalBatchesCommitted: 10,
            totalBatchesVerified: 8,
            totalBatchesExecuted: 5,
            l2SystemContractsUpgradeBatchNumber: 0,
            l2SystemContractsUpgradeTxHash: bytes32(0),
            priorityTree: priorityTreeCommitment,
            batchHashes: new bytes32[](2), // Wrong number
            isPermanentRollup: false,
            precommitmentForTheLatestBatch: bytes32(0)
        });

        bytes memory data = abi.encode(commitment);

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(InvalidNumberOfBatchHashes.selector, 2, 6));
        adminFacet.forwardedBridgeMint(data, false);
    }

    /*//////////////////////////////////////////////////////////////
                forwardedBridgeConfirmTransferResult Tests
    //////////////////////////////////////////////////////////////*/

    function test_forwardedBridgeConfirmTransferResult_RevertWhen_NotChainAssetHandler() public {
        address notHandler = makeAddr("notHandler");
        bytes memory data = abi.encode(uint256(1));

        vm.prank(notHandler);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, notHandler));
        adminFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Failure, bytes32(0), address(0), data);
    }

    function test_forwardedBridgeConfirmTransferResult_Success_ReturnsEarlyOnSuccess() public {
        bytes memory data = abi.encode(uint256(1));

        // Should return early without checking migration state when TxStatus.Success
        vm.prank(chainAssetHandler);
        adminFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Success, bytes32(0), address(0), data);
    }

    function test_forwardedBridgeConfirmTransferResult_RevertWhen_NotMigrated() public {
        bytes memory data = abi.encode(utilsFacet.util_getProtocolVersion());

        // Settlement layer is address(0) which means not migrated
        vm.prank(chainAssetHandler);
        vm.expectRevert(NotMigrated.selector);
        adminFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Failure, bytes32(0), address(0), data);
    }

    function test_forwardedBridgeConfirmTransferResult_RevertWhen_OutdatedProtocolVersion() public {
        uint256 currentProtocolVersion = utilsFacet.util_getProtocolVersion();
        uint256 differentVersion = currentProtocolVersion + 1;
        bytes memory data = abi.encode(differentVersion);

        // Set settlement layer to non-zero to simulate migrated state
        utilsFacet.util_setSettlementLayer(makeAddr("settlementLayer"));

        vm.prank(chainAssetHandler);
        vm.expectRevert(abi.encodeWithSelector(OutdatedProtocolVersion.selector, differentVersion, currentProtocolVersion));
        adminFacet.forwardedBridgeConfirmTransferResult(1, TxStatus.Failure, bytes32(0), address(0), data);
    }

    // add this to be excluded from coverage report
    function test() internal override {}
}

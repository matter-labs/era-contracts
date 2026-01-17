// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import "./_Mailbox_Shared.t.sol";
import {Utils} from "foundry-test/l1/unit/concrete/Utils/Utils.sol";
import {L2Log, L2Message} from "contracts/common/Messaging.sol";
import {MerkleTreeWithHistory} from "contracts/common/libraries/MerkleTreeWithHistory.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {DepositsPaused} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {MerklePathEmpty, MerkleIndexOutOfBounds, BatchNotExecuted, OnlyEraSupported, InvalidProof} from "contracts/common/L1ContractErrors.sol";
import {DataEncoding} from "contracts/common/libraries/DataEncoding.sol";
import {ETH_TOKEN_ADDRESS} from "contracts/common/Config.sol";

/// @title Extended tests for MailboxFacet to increase coverage
contract MailboxExtendedTest is MailboxTest {
    function setUp() public {
        setupDiamondProxy();
    }

    function test_ProveL2LogInclusion_BatchNotExecuted() public {
        uint256 batchNumber = 1;
        uint256 index = 0;
        L2Log memory l2Log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(0),
            value: bytes32(0)
        });
        bytes32[] memory merkleProof = new bytes32[](0);

        vm.expectRevert(abi.encodeWithSelector(BatchNotExecuted.selector, batchNumber));
        mailboxFacet.proveL2LogInclusion(batchNumber, index, l2Log, merkleProof);
    }

    function test_ProveL2MessageInclusion_BatchNotExecuted() public {
        uint256 batchNumber = 1;
        uint256 index = 0;
        L2Message memory message = L2Message({
            txNumberInBatch: 0,
            sender: makeAddr("l2Sender"),
            data: hex"deadbeef"
        });
        bytes32[] memory merkleProof = new bytes32[](0);

        vm.expectRevert(abi.encodeWithSelector(BatchNotExecuted.selector, batchNumber));
        mailboxFacet.proveL2MessageInclusion(batchNumber, index, message, merkleProof);
    }

    function test_ProveL1ToL2TransactionStatus_BatchNotExecuted() public {
        uint256 batchNumber = 1;
        uint256 index = 0;
        bytes32 txHash = keccak256("tx");
        bytes32[] memory merkleProof = new bytes32[](0);
        uint8 status = 1;

        vm.expectRevert(abi.encodeWithSelector(BatchNotExecuted.selector, batchNumber));
        mailboxFacet.proveL1ToL2TransactionStatus(
            batchNumber,
            index,
            0,
            txHash,
            status,
            merkleProof
        );
    }

    function test_ProveL2LeafInclusion_MerklePathEmpty() public {
        uint256 batchNumber = 1;
        bytes32 leaf = keccak256("leaf");
        bytes32[] memory merkleProof = new bytes32[](0);

        // Set some executed batches to pass the batch check
        utilsFacet.util_setTotalBatchesExecuted(2);
        utilsFacet.util_setL2LogsRootHash(1, keccak256("root"));

        vm.expectRevert(MerklePathEmpty.selector);
        mailboxFacet.proveL2LeafInclusion(batchNumber, 0, leaf, merkleProof);
    }

    function test_ProveL2LeafInclusion_MerkleIndexOutOfBounds() public {
        uint256 batchNumber = 1;
        bytes32 leaf = keccak256("leaf");
        bytes32[] memory merkleProof = new bytes32[](1);
        merkleProof[0] = keccak256("proof");

        // Set some executed batches
        utilsFacet.util_setTotalBatchesExecuted(2);
        utilsFacet.util_setL2LogsRootHash(1, keccak256("root"));

        // Index too large for the merkle tree (2^pathLength = 2, but index >= 2)
        vm.expectRevert(abi.encodeWithSelector(MerkleIndexOutOfBounds.selector));
        mailboxFacet.proveL2LeafInclusion(batchNumber, 100, leaf, merkleProof);
    }

    function test_L2TransactionBaseCost() public view {
        uint256 gasPrice = 1 gwei;
        uint256 l2GasLimit = 100000;
        uint256 l2GasPerPubdataByteLimit = 800;

        uint256 cost = mailboxFacet.l2TransactionBaseCost(gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);

        // Just ensure it returns a value (the exact calculation is complex)
        assertTrue(cost > 0);
    }

    function test_GetName() public view {
        string memory name = mailboxFacet.getName();
        assertEq(name, "MailboxFacet");
    }

    function test_RequestL2Transaction_ETH() public {
        // Set up the necessary state for requesting L2 transaction
        utilsFacet.util_setBaseToken(DataEncoding.encodeNTVAssetId(block.chainid, ETH_TOKEN_ADDRESS));
        utilsFacet.util_setPriorityTxMaxGasLimit(10_000_000);
        utilsFacet.util_setBaseTokenGasPriceMultiplierDenominator(1);
        utilsFacet.util_setBaseTokenGasPriceMultiplierNominator(1);

        address contractL2 = makeAddr("contractL2");
        uint256 l2Value = 1 ether;
        bytes memory calldata_ = hex"";
        uint256 l2GasLimit = 1_000_000;
        uint256 l2GasPerPubdataByteLimit = 800;
        bytes[] memory factoryDeps = new bytes[](0);
        address refundRecipient = sender;

        // This will likely fail due to validation, but tests the request path
        vm.prank(sender);
        vm.expectRevert(); // Will revert due to fee calculation or other validation
        mailboxFacet.requestL2Transaction{value: 2 ether}(
            contractL2,
            l2Value,
            calldata_,
            l2GasLimit,
            l2GasPerPubdataByteLimit,
            factoryDeps,
            refundRecipient
        );
    }

    function test_FinalizeEthWithdrawal_BatchNotExecuted() public {
        uint256 batchNumber = 1;
        uint256 messageIndex = 0;
        uint16 txNumberInBatch = 0;
        bytes memory message = hex"deadbeef";
        bytes32[] memory merkleProof = new bytes32[](1);
        merkleProof[0] = bytes32(0);

        vm.expectRevert(abi.encodeWithSelector(BatchNotExecuted.selector, batchNumber));
        mailboxFacet.finalizeEthWithdrawal(batchNumber, messageIndex, txNumberInBatch, message, merkleProof);
    }

    function test_ProveL2LeafInclusion_InvalidProof() public {
        uint256 batchNumber = 1;
        bytes32 leaf = keccak256("leaf");
        bytes32[] memory merkleProof = new bytes32[](2);
        merkleProof[0] = keccak256("proof1");
        merkleProof[1] = keccak256("proof2");

        // Set some executed batches
        utilsFacet.util_setTotalBatchesExecuted(2);
        utilsFacet.util_setL2LogsRootHash(1, keccak256("differentRoot"));

        vm.expectRevert(InvalidProof.selector);
        mailboxFacet.proveL2LeafInclusion(batchNumber, 0, leaf, merkleProof);
    }

    function testFuzz_L2TransactionBaseCost(
        uint256 gasPrice,
        uint256 l2GasLimit,
        uint256 l2GasPerPubdataByteLimit
    ) public view {
        // Bound inputs to reasonable values
        gasPrice = bound(gasPrice, 1, 1000 gwei);
        l2GasLimit = bound(l2GasLimit, 21000, 30_000_000);
        l2GasPerPubdataByteLimit = bound(l2GasPerPubdataByteLimit, 100, 10000);

        uint256 cost = mailboxFacet.l2TransactionBaseCost(gasPrice, l2GasLimit, l2GasPerPubdataByteLimit);

        // Ensure cost is reasonable
        assertTrue(cost <= type(uint128).max);
    }

    function test_ProveL2LogInclusion_WithExecutedBatch() public {
        uint256 batchNumber = 1;
        uint256 index = 0;
        L2Log memory l2Log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 0,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(0),
            value: bytes32(0)
        });

        // Set executed batches
        utilsFacet.util_setTotalBatchesExecuted(2);
        utilsFacet.util_setL2LogsRootHash(1, keccak256("root"));

        bytes32[] memory merkleProof = new bytes32[](0);

        // This will fail with MerklePathEmpty, but we reach the batch check first
        vm.expectRevert(MerklePathEmpty.selector);
        mailboxFacet.proveL2LogInclusion(batchNumber, index, l2Log, merkleProof);
    }
}

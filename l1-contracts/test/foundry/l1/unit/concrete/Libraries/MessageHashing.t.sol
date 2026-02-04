// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {MessageHashing, BATCH_LEAF_PADDING, CHAIN_ID_LEAF_PADDING} from "contracts/common/libraries/MessageHashing.sol";
import {L2Log, L2Message, TxStatus} from "contracts/common/Messaging.sol";
import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {MerklePathEmpty, HashedLogIsDefault, InvalidProofLengthForFinalNode} from "contracts/common/L1ContractErrors.sol";
import {UnsupportedProofMetadataVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {L2_L1_LOGS_TREE_DEFAULT_LEAF_HASH, SUPPORTED_PROOF_METADATA_VERSION} from "contracts/common/Config.sol";

/// @notice Unit tests for MessageHashing library
contract MessageHashingTest is Test {
    // ============ getLeafHashFromMessage Tests ============

    function test_getLeafHashFromMessage_basicValues() public pure {
        L2Message memory message = L2Message({txNumberInBatch: 1, sender: address(0x1234), data: hex"aabbcc"});

        bytes32 leafHash = MessageHashing.getLeafHashFromMessage(message);

        // Should be non-zero
        assertTrue(leafHash != bytes32(0));
    }

    function test_getLeafHashFromMessage_deterministicOutput() public pure {
        L2Message memory message = L2Message({txNumberInBatch: 5, sender: address(0x5678), data: hex"deadbeef"});

        bytes32 leafHash1 = MessageHashing.getLeafHashFromMessage(message);
        bytes32 leafHash2 = MessageHashing.getLeafHashFromMessage(message);

        assertEq(leafHash1, leafHash2);
    }

    // ============ getL2LogFromL1ToL2Transaction Tests ============

    function test_getL2LogFromL1ToL2Transaction_success() public pure {
        uint16 txNumberInBatch = 42;
        bytes32 l2TxHash = keccak256("txHash");
        TxStatus status = TxStatus.Success;

        L2Log memory log = MessageHashing.getL2LogFromL1ToL2Transaction(txNumberInBatch, l2TxHash, status);

        assertEq(log.l2ShardId, 0);
        assertTrue(log.isService);
        assertEq(log.txNumberInBatch, txNumberInBatch);
        assertEq(log.sender, L2_BOOTLOADER_ADDRESS);
        assertEq(log.key, l2TxHash);
        assertEq(log.value, bytes32(uint256(1))); // Success = 1
    }

    function test_getL2LogFromL1ToL2Transaction_failure() public pure {
        uint16 txNumberInBatch = 42;
        bytes32 l2TxHash = keccak256("txHash");
        TxStatus status = TxStatus.Failure;

        L2Log memory log = MessageHashing.getL2LogFromL1ToL2Transaction(txNumberInBatch, l2TxHash, status);

        assertEq(log.value, bytes32(uint256(0))); // Failure = 0
    }

    // ============ getLeafHashFromLog Tests ============

    function test_getLeafHashFromLog_basicValues() public pure {
        L2Log memory log = L2Log({
            l2ShardId: 0,
            isService: true,
            txNumberInBatch: 10,
            sender: L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
            key: bytes32(uint256(0x1234)),
            value: keccak256("data")
        });

        bytes32 leafHash = MessageHashing.getLeafHashFromLog(log);

        // Should be the keccak of the packed fields
        bytes32 expected = keccak256(
            abi.encodePacked(log.l2ShardId, log.isService, log.txNumberInBatch, log.sender, log.key, log.value)
        );
        assertEq(leafHash, expected);
    }

    // ============ batchLeafHash Tests ============

    function test_batchLeafHash_basicValues() public pure {
        bytes32 batchRoot = keccak256("batchRoot");
        uint256 batchNumber = 100;

        bytes32 leafHash = MessageHashing.batchLeafHash(batchRoot, batchNumber);

        bytes32 expected = keccak256(abi.encodePacked(BATCH_LEAF_PADDING, batchRoot, batchNumber));
        assertEq(leafHash, expected);
    }

    function testFuzz_batchLeafHash_deterministicOutput(bytes32 batchRoot, uint256 batchNumber) public pure {
        bytes32 leafHash1 = MessageHashing.batchLeafHash(batchRoot, batchNumber);
        bytes32 leafHash2 = MessageHashing.batchLeafHash(batchRoot, batchNumber);
        assertEq(leafHash1, leafHash2);
    }

    // ============ chainIdLeafHash Tests ============

    function test_chainIdLeafHash_basicValues() public pure {
        bytes32 chainIdRoot = keccak256("chainIdRoot");
        uint256 chainId = 1;

        bytes32 leafHash = MessageHashing.chainIdLeafHash(chainIdRoot, chainId);

        bytes32 expected = keccak256(abi.encodePacked(CHAIN_ID_LEAF_PADDING, chainIdRoot, chainId));
        assertEq(leafHash, expected);
    }

    function testFuzz_chainIdLeafHash_deterministicOutput(bytes32 chainIdRoot, uint256 chainId) public pure {
        bytes32 leafHash1 = MessageHashing.chainIdLeafHash(chainIdRoot, chainId);
        bytes32 leafHash2 = MessageHashing.chainIdLeafHash(chainIdRoot, chainId);
        assertEq(leafHash1, leafHash2);
    }

    // ============ parseProofMetadata Tests ============

    function test_parseProofMetadata_newFormat() public {
        // New format: first byte is version (0x01), then logLeafProofLen, batchLeafProofLen, finalProofNode
        bytes32 metadata = bytes32(
            abi.encodePacked(bytes1(uint8(SUPPORTED_PROOF_METADATA_VERSION)), bytes1(0x10), bytes1(0x00), bytes1(0x01))
        );

        bytes32[] memory proof = new bytes32[](17); // 1 metadata + 16 proof elements
        proof[0] = metadata;

        MessageHashing.ProofMetadata memory result = this.externalParseProofMetadata(proof);

        assertEq(result.proofStartIndex, 1);
        assertEq(result.logLeafProofLen, 16);
        assertEq(result.batchLeafProofLen, 0);
        assertTrue(result.finalProofNode);
    }

    function test_parseProofMetadata_oldFormat() public {
        // Old format: just proof elements (no metadata prefix)
        bytes32[] memory proof = new bytes32[](10);
        proof[0] = keccak256("proof element"); // Non-zero value that doesn't look like metadata

        MessageHashing.ProofMetadata memory result = this.externalParseProofMetadata(proof);

        assertEq(result.proofStartIndex, 0);
        assertEq(result.logLeafProofLen, 10);
        assertEq(result.batchLeafProofLen, 0);
        assertTrue(result.finalProofNode);
    }

    function test_parseProofMetadata_revertsOnUnsupportedVersion() public {
        // Create metadata with unsupported version (0x02)
        bytes32 metadata = bytes32(abi.encodePacked(bytes1(0x02), bytes1(0x10), bytes1(0x00), bytes1(0x01)));

        bytes32[] memory proof = new bytes32[](1);
        proof[0] = metadata;

        vm.expectRevert(abi.encodeWithSelector(UnsupportedProofMetadataVersion.selector, uint256(2)));
        this.externalParseProofMetadata(proof);
    }

    function test_parseProofMetadata_revertsOnInvalidFinalNodeWithBatchProof() public {
        // Create metadata with finalProofNode=true but batchLeafProofLen != 0
        bytes32 metadata = bytes32(
            abi.encodePacked(bytes1(uint8(SUPPORTED_PROOF_METADATA_VERSION)), bytes1(0x10), bytes1(0x05), bytes1(0x01))
        );

        bytes32[] memory proof = new bytes32[](22); // 1 metadata + 16 log proof + 5 batch proof
        proof[0] = metadata;

        vm.expectRevert(InvalidProofLengthForFinalNode.selector);
        this.externalParseProofMetadata(proof);
    }

    // External wrapper for calldata conversion
    function externalParseProofMetadata(
        bytes32[] calldata _proof
    ) external pure returns (MessageHashing.ProofMetadata memory) {
        return MessageHashing.parseProofMetadata(_proof);
    }

    // ============ extractSlice Tests ============

    function test_extractSlice_basicValues() public {
        bytes32[] memory proof = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            proof[i] = bytes32(i);
        }

        bytes32[] memory slice = this.externalExtractSlice(proof, 1, 4);

        assertEq(slice.length, 3);
        assertEq(slice[0], bytes32(uint256(1)));
        assertEq(slice[1], bytes32(uint256(2)));
        assertEq(slice[2], bytes32(uint256(3)));
    }

    function test_extractSlice_emptySlice() public {
        bytes32[] memory proof = new bytes32[](5);

        bytes32[] memory slice = this.externalExtractSlice(proof, 2, 2);

        assertEq(slice.length, 0);
    }

    // External wrapper for calldata conversion
    function externalExtractSlice(
        bytes32[] calldata _proof,
        uint256 _left,
        uint256 _right
    ) external pure returns (bytes32[] memory) {
        return MessageHashing.extractSlice(_proof, _left, _right);
    }

    // ============ extractSliceUntilEnd Tests ============

    function test_extractSliceUntilEnd_basicValues() public {
        bytes32[] memory proof = new bytes32[](5);
        for (uint256 i = 0; i < 5; i++) {
            proof[i] = bytes32(i);
        }

        bytes32[] memory slice = this.externalExtractSliceUntilEnd(proof, 3);

        assertEq(slice.length, 2);
        assertEq(slice[0], bytes32(uint256(3)));
        assertEq(slice[1], bytes32(uint256(4)));
    }

    // External wrapper for calldata conversion
    function externalExtractSliceUntilEnd(
        bytes32[] calldata _proof,
        uint256 _start
    ) external pure returns (bytes32[] memory) {
        return MessageHashing.extractSliceUntilEnd(_proof, _start);
    }
}

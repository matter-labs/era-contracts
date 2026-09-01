// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BATCH_LEAF_PADDING, CHAIN_ID_LEAF_PADDING, MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {L2Log, L2Message, ProofData, TxStatus} from "contracts/common/Messaging.sol";
import {
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_BOOTLOADER_ADDRESS
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    MerklePathEmpty,
    HashedLogIsDefault,
    InvalidProofLengthForFinalNode
} from "contracts/common/L1ContractErrors.sol";
import {UnsupportedProofMetadataVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {SUPPORTED_PROOF_METADATA_VERSION} from "contracts/common/Config.sol";

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

        bytes32 leafHash = MessageHashing.batchLeafHash(batchRoot, batchNumber, 0);

        bytes32 expected = keccak256(abi.encodePacked(BATCH_LEAF_PADDING, batchRoot, batchNumber, uint256(0)));
        assertEq(leafHash, expected);
    }

    /// @dev `l1Timestamp` must be part of the leaf preimage. See {protocol-docs/message-root.md#v31-vs-v33-append-flows}.
    function test_batchLeafHash_bindsL1Timestamp() public pure {
        bytes32 batchRoot = keccak256("batchRoot");
        uint256 batchNumber = 100;
        uint256 l1Timestamp = 1_700_000_000;

        bytes32 leafHash = MessageHashing.batchLeafHash(batchRoot, batchNumber, l1Timestamp);

        assertEq(leafHash, keccak256(abi.encodePacked(BATCH_LEAF_PADDING, batchRoot, batchNumber, l1Timestamp)));
        assertTrue(leafHash != MessageHashing.batchLeafHash(batchRoot, batchNumber, 0));
    }

    function testFuzz_batchLeafHash_matchesSpecWithTimestamp(
        bytes32 batchRoot,
        uint256 batchNumber,
        uint256 l1Timestamp
    ) public pure {
        assertEq(
            MessageHashing.batchLeafHash(batchRoot, batchNumber, l1Timestamp),
            keccak256(abi.encodePacked(BATCH_LEAF_PADDING, batchRoot, batchNumber, l1Timestamp))
        );
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

    // ============ readSettlementLayerReference / readAggregationHopPath Tests ============

    /// @dev Builds a well-formed *non-final* multi-hop proof in the exact word layout `_getProofData`
    /// consumes: [metadata][logLeafProofLen siblings][l1Timestamp][batchLeafProofMask]
    /// [batchLeafProofLen siblings][(slBlock << 128) | slRootMask][slChainId].
    function _buildMultiHopProof(
        uint256 _logLeafProofLen,
        uint256 _batchLeafProofLen,
        uint256 _l1Timestamp,
        uint256 _batchLeafProofMask,
        uint128 _slBlock,
        uint128 _slRootMask,
        uint256 _slChainId
    ) internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](5 + _logLeafProofLen + _batchLeafProofLen);
        proof[0] = bytes32(
            (uint256(SUPPORTED_PROOF_METADATA_VERSION) << 248) | (_logLeafProofLen << 240) | (_batchLeafProofLen << 232)
        );
        for (uint256 i = 0; i < _logLeafProofLen; i++) {
            proof[1 + i] = keccak256(abi.encode("log-sibling", i));
        }
        proof[1 + _logLeafProofLen] = bytes32(_l1Timestamp);
        proof[2 + _logLeafProofLen] = bytes32(_batchLeafProofMask);
        for (uint256 i = 0; i < _batchLeafProofLen; i++) {
            proof[3 + _logLeafProofLen + i] = keccak256(abi.encode("batch-sibling", i));
        }
        proof[3 + _logLeafProofLen + _batchLeafProofLen] = bytes32((uint256(_slBlock) << 128) | uint256(_slRootMask));
        proof[4 + _logLeafProofLen + _batchLeafProofLen] = bytes32(_slChainId);
    }

    /// @dev Pins `readSettlementLayerReference`'s positional offsets to `_getProofData`'s pointer
    /// walk: both parsers must recover the same settlement-layer words from the same proof bytes,
    /// for any metadata-declared section lengths. This is the drift guard for the word layout being
    /// implemented in two places.
    function testFuzz_readSettlementLayerReference_matchesGetProofData(
        uint8 _logLeafProofLenSeed,
        uint8 _batchLeafProofLenSeed,
        uint256 _l1Timestamp,
        uint256 _batchLeafProofMask,
        uint128 _slBlock,
        uint128 _slRootMask,
        uint256 _slChainId
    ) public {
        uint256 logLeafProofLen = bound(_logLeafProofLenSeed, 1, 32);
        uint256 batchLeafProofLen = bound(_batchLeafProofLenSeed, 0, 16);
        // `_getProofData` runs a real Merkle climb over the batch-leaf section, so the mask must
        // address a leaf inside a tree of that depth.
        uint256 batchLeafProofMask = bound(_batchLeafProofMask, 0, (1 << batchLeafProofLen) - 1);
        bytes32[] memory proof = _buildMultiHopProof(
            logLeafProofLen,
            batchLeafProofLen,
            _l1Timestamp,
            batchLeafProofMask,
            _slBlock,
            _slRootMask,
            _slChainId
        );

        ProofData memory proofData = this.externalGetProofData(1, 1, 0, keccak256("leaf"), proof);
        MessageHashing.SettlementLayerReference memory slReference = this.externalReadSettlementLayerReference(proof);

        assertEq(slReference.l1BatchTimestamp, proofData.l1BatchTimestamp);
        assertEq(slReference.settlementLayerBatchNumber, proofData.settlementLayerBatchNumber);
        assertEq(slReference.settlementLayerChainId, proofData.settlementLayerChainId);
        // Sanity: both parsers recovered the values actually written into the proof.
        assertEq(slReference.l1BatchTimestamp, _l1Timestamp);
        assertEq(slReference.settlementLayerBatchNumber, uint256(_slBlock));
        assertEq(slReference.settlementLayerChainId, _slChainId);
    }

    /// @dev The batch-leaf path accessor must agree with the words written into the proof (mask +
    /// siblings), for any section lengths.
    function testFuzz_readAggregationHopPath_matchesProofWords(
        uint8 _logLeafProofLenSeed,
        uint8 _batchLeafProofLenSeed,
        uint256 _batchLeafProofMask
    ) public {
        uint256 logLeafProofLen = bound(_logLeafProofLenSeed, 1, 32);
        uint256 batchLeafProofLen = bound(_batchLeafProofLenSeed, 0, 16);
        bytes32[] memory proof = _buildMultiHopProof(
            logLeafProofLen,
            batchLeafProofLen,
            0,
            _batchLeafProofMask,
            0,
            0,
            0
        );

        MessageHashing.AggregationHopPath memory path = this.externalReadAggregationHopPath(proof);

        assertEq(path.batchLeafProofMask, _batchLeafProofMask);
        assertEq(path.batchLeafSiblings.length, batchLeafProofLen);
        for (uint256 i = 0; i < batchLeafProofLen; i++) {
            assertEq(path.batchLeafSiblings[i], keccak256(abi.encode("batch-sibling", i)));
        }
    }

    /// @dev A final-node proof carries no settlement-layer batch reference; the accessor must
    /// fail closed even when trailing padding words would make the positional reads in-bounds.
    function test_readSettlementLayerReference_revertsOnFinalProofNode() public {
        bytes32[] memory proof = _paddedFinalProof();

        vm.expectRevert(InvalidProofLengthForFinalNode.selector);
        this.externalReadSettlementLayerReference(proof);
    }

    /// @dev Same fail-closed behavior for the batch-leaf path accessor.
    function test_readAggregationHopPath_revertsOnFinalProofNode() public {
        bytes32[] memory proof = _paddedFinalProof();

        vm.expectRevert(InvalidProofLengthForFinalNode.selector);
        this.externalReadAggregationHopPath(proof);
    }

    /// @dev A final-node proof (2 log-leaf siblings) padded with attacker-chosen trailing words at
    /// the offsets the accessors would otherwise read.
    function _paddedFinalProof() internal pure returns (bytes32[] memory proof) {
        proof = new bytes32[](8);
        proof[0] = bytes32(
            (uint256(SUPPORTED_PROOF_METADATA_VERSION) << 248) | (uint256(2) << 240) | (uint256(1) << 224)
        );
        for (uint256 i = 1; i < 8; i++) {
            proof[i] = keccak256(abi.encode("padding", i));
        }
    }

    // External wrappers for calldata conversion
    function externalGetProofData(
        uint256 _chainId,
        uint256 _batchNumber,
        uint256 _leafProofMask,
        bytes32 _leaf,
        bytes32[] calldata _proof
    ) external pure returns (ProofData memory) {
        return MessageHashing._getProofData(_chainId, _batchNumber, _leafProofMask, _leaf, _proof);
    }

    function externalReadSettlementLayerReference(
        bytes32[] calldata _proof
    ) external pure returns (MessageHashing.SettlementLayerReference memory) {
        return MessageHashing.readSettlementLayerReference(_proof);
    }

    function externalReadAggregationHopPath(
        bytes32[] calldata _proof
    ) external pure returns (MessageHashing.AggregationHopPath memory) {
        return MessageHashing.readAggregationHopPath(_proof);
    }
}

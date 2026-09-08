// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {
    CommitBatchInfo,
    CommitBatchInfoZKsyncOS,
    PrecommitInfo
} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {InteropRoot, L2Log} from "contracts/common/Messaging.sol";
import {
    EmptyData,
    IncorrectBatchBounds,
    UnsupportedCommitBatchEncoding,
    UnsupportedExecuteBatchEncoding,
    UnsupportedProofBatchEncoding
} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for BatchDecoder library
contract BatchDecoderTest is Test {
    /// @dev Mirrored from `BatchDecoder` rather than imported, so that a version change has to be
    /// made deliberately here too. The previous values are kept below to pin rejection of payloads
    /// a client encoded under the pre-Airbender layout.
    uint8 constant SUPPORTED_ENCODING_VERSION = 5;
    uint8 constant SUPPORTED_ENCODING_VERSION_COMMIT_ZKSYNC_OS = 6;
    uint8 constant SUPPORTED_ENCODING_VERSION_PRECOMMIT = 1;
    uint8 constant PRE_AIRBENDER_ENCODING_VERSION = 1;
    uint8 constant PRE_AIRBENDER_ENCODING_VERSION_COMMIT_ZKSYNC_OS = 4;

    // ============ decodeAndCheckCommitData Tests ============

    function test_decodeAndCheckCommitData_basicValues() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfo[] memory newBatches = new CommitBatchInfo[](2);
        newBatches[0] = _createCommitBatchInfo(11);
        newBatches[1] = _createCommitBatchInfo(12);

        bytes memory encodedData = abi.encodePacked(SUPPORTED_ENCODING_VERSION, abi.encode(lastBatch, newBatches));

        (IExecutor.StoredBatchInfo memory decodedLastBatch, CommitBatchInfo[] memory decodedNewBatches) = this
            .externalDecodeAndCheckCommitData(encodedData, 11, 12);

        assertEq(decodedLastBatch.batchNumber, 10);
        assertEq(decodedNewBatches.length, 2);
        assertEq(decodedNewBatches[0].batchNumber, 11);
        assertEq(decodedNewBatches[1].batchNumber, 12);
    }

    function test_decodeAndCheckCommitData_singleBatch() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(5);
        CommitBatchInfo[] memory newBatches = new CommitBatchInfo[](1);
        newBatches[0] = _createCommitBatchInfo(6);

        bytes memory encodedData = abi.encodePacked(SUPPORTED_ENCODING_VERSION, abi.encode(lastBatch, newBatches));

        (IExecutor.StoredBatchInfo memory decodedLastBatch, CommitBatchInfo[] memory decodedNewBatches) = this
            .externalDecodeAndCheckCommitData(encodedData, 6, 6);

        assertEq(decodedLastBatch.batchNumber, 5);
        assertEq(decodedNewBatches.length, 1);
        assertEq(decodedNewBatches[0].batchNumber, 6);
    }

    function test_decodeAndCheckCommitData_revertsOnEmptyData() public {
        bytes memory emptyData = "";

        vm.expectRevert(EmptyData.selector);
        this.externalDecodeAndCheckCommitData(emptyData, 1, 1);
    }

    function test_decodeAndCheckCommitData_revertsOnUnsupportedVersion() public {
        uint8 unsupportedVersion = 99;
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfo[] memory newBatches = new CommitBatchInfo[](1);
        newBatches[0] = _createCommitBatchInfo(11);

        bytes memory encodedData = abi.encodePacked(unsupportedVersion, abi.encode(lastBatch, newBatches));

        vm.expectRevert(abi.encodeWithSelector(UnsupportedCommitBatchEncoding.selector, unsupportedVersion));
        this.externalDecodeAndCheckCommitData(encodedData, 11, 11);
    }

    function test_decodeAndCheckCommitData_revertsOnIncorrectBounds() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfo[] memory newBatches = new CommitBatchInfo[](2);
        newBatches[0] = _createCommitBatchInfo(11);
        newBatches[1] = _createCommitBatchInfo(12);

        bytes memory encodedData = abi.encodePacked(SUPPORTED_ENCODING_VERSION, abi.encode(lastBatch, newBatches));

        // Wrong bounds
        vm.expectRevert(abi.encodeWithSelector(IncorrectBatchBounds.selector, 100, 200, 11, 12));
        this.externalDecodeAndCheckCommitData(encodedData, 100, 200);
    }

    function test_decodeAndCheckCommitData_revertsOnEmptyNewBatches() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfo[] memory newBatches = new CommitBatchInfo[](0);

        bytes memory encodedData = abi.encodePacked(SUPPORTED_ENCODING_VERSION, abi.encode(lastBatch, newBatches));

        vm.expectRevert(EmptyData.selector);
        this.externalDecodeAndCheckCommitData(encodedData, 1, 1);
    }

    // ============ decodeAndCheckProofData Tests ============

    function test_decodeAndCheckProofData_basicValues() public {
        IExecutor.StoredBatchInfo memory prevBatch = _createStoredBatchInfo(10);
        IExecutor.StoredBatchInfo[] memory provedBatches = new IExecutor.StoredBatchInfo[](2);
        provedBatches[0] = _createStoredBatchInfo(11);
        provedBatches[1] = _createStoredBatchInfo(12);
        uint256[] memory proof = new uint256[](3);
        proof[0] = 1;
        proof[1] = 2;
        proof[2] = 3;

        bytes memory encodedData = abi.encodePacked(
            SUPPORTED_ENCODING_VERSION,
            abi.encode(prevBatch, provedBatches, proof)
        );

        (
            IExecutor.StoredBatchInfo memory decodedPrevBatch,
            IExecutor.StoredBatchInfo[] memory decodedProvedBatches,
            uint256[] memory decodedProof
        ) = this.externalDecodeAndCheckProofData(encodedData, 11, 12);

        assertEq(decodedPrevBatch.batchNumber, 10);
        assertEq(decodedProvedBatches.length, 2);
        assertEq(decodedProvedBatches[0].batchNumber, 11);
        assertEq(decodedProvedBatches[1].batchNumber, 12);
        assertEq(decodedProof.length, 3);
    }

    function test_decodeAndCheckProofData_revertsOnUnsupportedVersion() public {
        uint8 unsupportedVersion = 99;
        IExecutor.StoredBatchInfo memory prevBatch = _createStoredBatchInfo(10);
        IExecutor.StoredBatchInfo[] memory provedBatches = new IExecutor.StoredBatchInfo[](1);
        provedBatches[0] = _createStoredBatchInfo(11);
        uint256[] memory proof = new uint256[](0);

        bytes memory encodedData = abi.encodePacked(unsupportedVersion, abi.encode(prevBatch, provedBatches, proof));

        vm.expectRevert(abi.encodeWithSelector(UnsupportedProofBatchEncoding.selector, unsupportedVersion));
        this.externalDecodeAndCheckProofData(encodedData, 11, 11);
    }

    function test_decodeAndCheckProofData_revertsOnIncorrectBounds() public {
        IExecutor.StoredBatchInfo memory prevBatch = _createStoredBatchInfo(10);
        IExecutor.StoredBatchInfo[] memory provedBatches = new IExecutor.StoredBatchInfo[](2);
        provedBatches[0] = _createStoredBatchInfo(11);
        provedBatches[1] = _createStoredBatchInfo(12);
        uint256[] memory proof = new uint256[](0);

        bytes memory encodedData = abi.encodePacked(
            SUPPORTED_ENCODING_VERSION,
            abi.encode(prevBatch, provedBatches, proof)
        );

        vm.expectRevert(abi.encodeWithSelector(IncorrectBatchBounds.selector, 100, 200, 11, 12));
        this.externalDecodeAndCheckProofData(encodedData, 100, 200);
    }

    function test_decodeAndCheckProofData_revertsOnEmptyProvedBatches() public {
        IExecutor.StoredBatchInfo memory prevBatch = _createStoredBatchInfo(10);
        IExecutor.StoredBatchInfo[] memory provedBatches = new IExecutor.StoredBatchInfo[](0);
        uint256[] memory proof = new uint256[](0);

        bytes memory encodedData = abi.encodePacked(
            SUPPORTED_ENCODING_VERSION,
            abi.encode(prevBatch, provedBatches, proof)
        );

        vm.expectRevert(EmptyData.selector);
        this.externalDecodeAndCheckProofData(encodedData, 1, 1);
    }

    // ============ decodeAndCheckExecuteData Tests ============

    function test_decodeAndCheckExecuteData_basicValues() public {
        IExecutor.StoredBatchInfo[] memory executeBatches = new IExecutor.StoredBatchInfo[](2);
        executeBatches[0] = _createStoredBatchInfo(11);
        executeBatches[1] = _createStoredBatchInfo(12);

        PriorityOpsBatchInfo[] memory priorityOps = new PriorityOpsBatchInfo[](2);
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](2);
        L2Log[][] memory logs = new L2Log[][](2);
        bytes[][] memory messages = new bytes[][](2);
        bytes32[] memory multichainBatchRoots = new bytes32[](2);

        bytes memory encodedData = abi.encodePacked(
            SUPPORTED_ENCODING_VERSION,
            abi.encode(executeBatches, priorityOps, dependencyRoots, logs, messages, multichainBatchRoots, address(0))
        );

        (
            IExecutor.StoredBatchInfo[] memory decodedExecuteBatches,
            PriorityOpsBatchInfo[] memory decodedPriorityOps,
            ,
            ,
            ,
            ,

        ) = this.externalDecodeAndCheckExecuteData(encodedData, 11, 12);

        assertEq(decodedExecuteBatches.length, 2);
        assertEq(decodedExecuteBatches[0].batchNumber, 11);
        assertEq(decodedExecuteBatches[1].batchNumber, 12);
        assertEq(decodedPriorityOps.length, 2);
    }

    function test_decodeAndCheckExecuteData_revertsOnEmptyData() public {
        bytes memory emptyData = "";

        vm.expectRevert(EmptyData.selector);
        this.externalDecodeAndCheckExecuteData(emptyData, 1, 1);
    }

    function test_decodeAndCheckExecuteData_revertsOnUnsupportedVersion() public {
        uint8 unsupportedVersion = 99;
        IExecutor.StoredBatchInfo[] memory executeBatches = new IExecutor.StoredBatchInfo[](1);
        executeBatches[0] = _createStoredBatchInfo(11);

        PriorityOpsBatchInfo[] memory priorityOps = new PriorityOpsBatchInfo[](1);
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](1);
        L2Log[][] memory logs = new L2Log[][](1);
        bytes[][] memory messages = new bytes[][](1);
        bytes32[] memory multichainBatchRoots = new bytes32[](1);

        bytes memory encodedData = abi.encodePacked(
            unsupportedVersion,
            abi.encode(executeBatches, priorityOps, dependencyRoots, logs, messages, multichainBatchRoots, address(0))
        );

        vm.expectRevert(abi.encodeWithSelector(UnsupportedExecuteBatchEncoding.selector, unsupportedVersion));
        this.externalDecodeAndCheckExecuteData(encodedData, 11, 11);
    }

    function test_decodeAndCheckExecuteData_revertsOnIncorrectBounds() public {
        IExecutor.StoredBatchInfo[] memory executeBatches = new IExecutor.StoredBatchInfo[](2);
        executeBatches[0] = _createStoredBatchInfo(11);
        executeBatches[1] = _createStoredBatchInfo(12);

        PriorityOpsBatchInfo[] memory priorityOps = new PriorityOpsBatchInfo[](2);
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](2);
        L2Log[][] memory logs = new L2Log[][](2);
        bytes[][] memory messages = new bytes[][](2);
        bytes32[] memory multichainBatchRoots = new bytes32[](2);

        bytes memory encodedData = abi.encodePacked(
            SUPPORTED_ENCODING_VERSION,
            abi.encode(executeBatches, priorityOps, dependencyRoots, logs, messages, multichainBatchRoots, address(0))
        );

        vm.expectRevert(abi.encodeWithSelector(IncorrectBatchBounds.selector, 100, 200, 11, 12));
        this.externalDecodeAndCheckExecuteData(encodedData, 100, 200);
    }

    function test_decodeAndCheckExecuteData_revertsOnEmptyExecuteBatches() public {
        IExecutor.StoredBatchInfo[] memory executeBatches = new IExecutor.StoredBatchInfo[](0);
        PriorityOpsBatchInfo[] memory priorityOps = new PriorityOpsBatchInfo[](0);
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](0);
        L2Log[][] memory logs = new L2Log[][](0);
        bytes[][] memory messages = new bytes[][](0);
        bytes32[] memory multichainBatchRoots = new bytes32[](0);

        bytes memory encodedData = abi.encodePacked(
            SUPPORTED_ENCODING_VERSION,
            abi.encode(executeBatches, priorityOps, dependencyRoots, logs, messages, multichainBatchRoots, address(0))
        );

        vm.expectRevert(EmptyData.selector);
        this.externalDecodeAndCheckExecuteData(encodedData, 1, 1);
    }

    // ============ decodeAndCheckPrecommitData Tests ============

    function test_decodeAndCheckPrecommitData_basicValues() public {
        PrecommitInfo memory precommitInfo = _createPrecommitInfo();

        bytes memory encodedData = abi.encodePacked(SUPPORTED_ENCODING_VERSION_PRECOMMIT, abi.encode(precommitInfo));

        PrecommitInfo memory decodedPrecommit = this.externalDecodeAndCheckPrecommitData(encodedData);

        assertEq(decodedPrecommit.packedTxsCommitments, precommitInfo.packedTxsCommitments);
        assertEq(decodedPrecommit.untrustedLastL2BlockNumberHint, precommitInfo.untrustedLastL2BlockNumberHint);
    }

    function test_decodeAndCheckPrecommitData_revertsOnUnsupportedVersion() public {
        uint8 unsupportedVersion = 99;
        PrecommitInfo memory precommitInfo = _createPrecommitInfo();

        bytes memory encodedData = abi.encodePacked(unsupportedVersion, abi.encode(precommitInfo));

        vm.expectRevert(abi.encodeWithSelector(UnsupportedCommitBatchEncoding.selector, unsupportedVersion));
        this.externalDecodeAndCheckPrecommitData(encodedData);
    }

    // ============ Pre-Airbender wire format ============

    /// `StoredBatchInfo` as a client encoded it before the Airbender field was appended.
    struct PreAirbenderStoredBatchInfo {
        uint64 batchNumber;
        bytes32 batchHash;
        uint64 indexRepeatedStorageChanges;
        uint256 numberOfLayer1Txs;
        bytes32 priorityOperationsHash;
        bytes32 dependencyRootsRollingHash;
        bytes32 l2LogsTreeRoot;
        uint256 timestamp;
        bytes32 commitment;
    }

    /// `CommitBatchInfo` as a client encoded it before `airbenderBootloaderHeapHash` was inserted.
    struct PreAirbenderCommitBatchInfo {
        uint64 batchNumber;
        uint64 timestamp;
        uint64 indexRepeatedStorageChanges;
        bytes32 newStateRoot;
        uint256 numberOfLayer1Txs;
        bytes32 priorityOperationsHash;
        bytes32 bootloaderHeapInitialContentsHash;
        bytes32 eventsQueueStateHash;
        bytes systemLogs;
        bytes operatorDAInput;
    }

    function _preAirbenderStoredBatch(uint64 _batchNumber) internal pure returns (PreAirbenderStoredBatchInfo memory) {
        return
            PreAirbenderStoredBatchInfo({
                batchNumber: _batchNumber,
                batchHash: keccak256(abi.encodePacked("batchHash", _batchNumber)),
                indexRepeatedStorageChanges: 1,
                numberOfLayer1Txs: 2,
                priorityOperationsHash: keccak256("priorityOperationsHash"),
                dependencyRootsRollingHash: keccak256("dependencyRootsRollingHash"),
                l2LogsTreeRoot: keccak256("l2LogsTreeRoot"),
                timestamp: 3,
                commitment: keccak256("commitment")
            });
    }

    /// A payload a client still on the previous schema would send: the old struct layout under the
    /// old version byte. It must be refused by name rather than decoded into the new shape, where
    /// the array offset word would land in `airbenderCommitment`.
    function test_decodeAndCheckCommitData_rejectsPreAirbenderPayload() public {
        PreAirbenderCommitBatchInfo[] memory oldBatches = new PreAirbenderCommitBatchInfo[](1);
        oldBatches[0] = PreAirbenderCommitBatchInfo({
            batchNumber: 11,
            timestamp: 0,
            indexRepeatedStorageChanges: 0,
            newStateRoot: bytes32(0),
            numberOfLayer1Txs: 0,
            priorityOperationsHash: bytes32(0),
            bootloaderHeapInitialContentsHash: bytes32(0),
            eventsQueueStateHash: bytes32(0),
            systemLogs: "",
            operatorDAInput: ""
        });

        bytes memory encodedData = abi.encodePacked(
            PRE_AIRBENDER_ENCODING_VERSION,
            abi.encode(_preAirbenderStoredBatch(10), oldBatches)
        );

        vm.expectRevert(
            abi.encodeWithSelector(UnsupportedCommitBatchEncoding.selector, PRE_AIRBENDER_ENCODING_VERSION)
        );
        this.externalDecodeAndCheckCommitData(encodedData, 11, 11);
    }

    function test_decodeAndCheckProofData_rejectsPreAirbenderPayload() public {
        PreAirbenderStoredBatchInfo[] memory proved = new PreAirbenderStoredBatchInfo[](1);
        proved[0] = _preAirbenderStoredBatch(11);

        bytes memory encodedData = abi.encodePacked(
            PRE_AIRBENDER_ENCODING_VERSION,
            abi.encode(_preAirbenderStoredBatch(10), proved, new uint256[](1))
        );

        vm.expectRevert(abi.encodeWithSelector(UnsupportedProofBatchEncoding.selector, PRE_AIRBENDER_ENCODING_VERSION));
        this.externalDecodeAndCheckProofData(encodedData, 11, 11);
    }

    function test_decodeAndCheckExecuteData_rejectsPreAirbenderPayload() public {
        PreAirbenderStoredBatchInfo[] memory batches = new PreAirbenderStoredBatchInfo[](1);
        batches[0] = _preAirbenderStoredBatch(11);

        bytes memory encodedData = abi.encodePacked(
            PRE_AIRBENDER_ENCODING_VERSION,
            abi.encode(batches, new PriorityOpsBatchInfo[](1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(UnsupportedExecuteBatchEncoding.selector, PRE_AIRBENDER_ENCODING_VERSION)
        );
        this.externalDecodeAndCheckExecuteData(encodedData, 11, 11);
    }

    /// ZKsync OS commit payloads embed the same struct, so their version moved too — the claim that
    /// those chains are untouched by this change is only true of the field's value, not the wire.
    function test_decodeAndCheckCommitDataZKsyncOS_rejectsPreAirbenderPayload() public {
        bytes memory encodedData = abi.encodePacked(
            PRE_AIRBENDER_ENCODING_VERSION_COMMIT_ZKSYNC_OS,
            abi.encode(_preAirbenderStoredBatch(10), new CommitBatchInfoZKsyncOS[](1))
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                UnsupportedCommitBatchEncoding.selector,
                PRE_AIRBENDER_ENCODING_VERSION_COMMIT_ZKSYNC_OS
            )
        );
        this.externalDecodeAndCheckCommitDataZKsyncOS(encodedData, 11, 11);
    }

    // ============ External Wrappers (for calldata) ============

    function externalDecodeAndCheckCommitDataZKsyncOS(
        bytes calldata _commitData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    ) external pure returns (IExecutor.StoredBatchInfo memory, CommitBatchInfoZKsyncOS[] memory) {
        return BatchDecoder.decodeAndCheckCommitDataZKsyncOS(_commitData, _processBatchFrom, _processBatchTo);
    }

    function externalDecodeAndCheckCommitData(
        bytes calldata _commitData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    ) external pure returns (IExecutor.StoredBatchInfo memory, CommitBatchInfo[] memory) {
        return BatchDecoder.decodeAndCheckCommitData(_commitData, _processBatchFrom, _processBatchTo);
    }

    function externalDecodeAndCheckProofData(
        bytes calldata _proofData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    ) external pure returns (IExecutor.StoredBatchInfo memory, IExecutor.StoredBatchInfo[] memory, uint256[] memory) {
        return BatchDecoder.decodeAndCheckProofData(_proofData, _processBatchFrom, _processBatchTo);
    }

    function externalDecodeAndCheckExecuteData(
        bytes calldata _executeData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    )
        external
        pure
        returns (
            IExecutor.StoredBatchInfo[] memory,
            PriorityOpsBatchInfo[] memory,
            InteropRoot[][] memory,
            L2Log[][] memory,
            bytes[][] memory,
            bytes32[] memory,
            address
        )
    {
        return BatchDecoder.decodeAndCheckExecuteData(_executeData, _processBatchFrom, _processBatchTo);
    }

    function externalDecodeAndCheckPrecommitData(
        bytes calldata _precommitData
    ) external pure returns (PrecommitInfo memory) {
        return BatchDecoder.decodeAndCheckPrecommitData(_precommitData);
    }

    // ============ Helper Functions ============

    function _createStoredBatchInfo(uint64 batchNumber) internal pure returns (IExecutor.StoredBatchInfo memory) {
        return
            IExecutor.StoredBatchInfo({
                batchNumber: batchNumber,
                batchHash: keccak256(abi.encodePacked(batchNumber)),
                indexRepeatedStorageChanges: 0,
                numberOfLayer1Txs: 0,
                priorityOperationsHash: bytes32(0),
                dependencyRootsRollingHash: bytes32(0),
                l2LogsTreeRoot: bytes32(0),
                timestamp: uint256(batchNumber) * 100,
                commitment: bytes32(0),
                airbenderCommitment: bytes32(0)
            });
    }

    function _createCommitBatchInfo(uint64 batchNumber) internal pure returns (CommitBatchInfo memory) {
        return
            CommitBatchInfo({
                batchNumber: batchNumber,
                timestamp: uint64(batchNumber) * 100,
                indexRepeatedStorageChanges: 0,
                newStateRoot: bytes32(0),
                numberOfLayer1Txs: 0,
                priorityOperationsHash: bytes32(0),
                bootloaderHeapInitialContentsHash: bytes32(0),
                eventsQueueStateHash: bytes32(0),
                airbenderBootloaderHeapHash: bytes32(0),
                systemLogs: "",
                operatorDAInput: ""
            });
    }

    function _createPrecommitInfo() internal pure returns (PrecommitInfo memory) {
        return PrecommitInfo({packedTxsCommitments: bytes("test_commitments"), untrustedLastL2BlockNumberHint: 12345});
    }
}

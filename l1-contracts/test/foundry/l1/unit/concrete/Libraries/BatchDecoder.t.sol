// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {BatchDecoder} from "contracts/state-transition/libraries/BatchDecoder.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {CommitBatchInfoZKsyncOS} from "contracts/state-transition/chain-interfaces/ICommitter.sol";
import {PriorityOpsBatchInfo} from "contracts/state-transition/libraries/PriorityTree.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {L2DACommitmentScheme} from "contracts/common/Config.sol";
import {
    EmptyData,
    IncorrectBatchBounds,
    UnsupportedCommitBatchEncoding,
    UnsupportedExecuteBatchEncoding,
    UnsupportedProofBatchEncoding
} from "contracts/common/L1ContractErrors.sol";

/// @notice Unit tests for BatchDecoder library
contract BatchDecoderTest is Test {
    // ============ decodeAndCheckCommitData Tests ============

    function test_decodeAndCheckCommitData_basicValues() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfoZKsyncOS[] memory newBatches = new CommitBatchInfoZKsyncOS[](2);
        newBatches[0] = _createCommitBatchInfoZKsyncOS(11);
        newBatches[1] = _createCommitBatchInfoZKsyncOS(12);

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT,
            abi.encode(lastBatch, newBatches)
        );

        (IExecutor.StoredBatchInfo memory decodedLastBatch, CommitBatchInfoZKsyncOS[] memory decodedNewBatches) = this
            .externalDecodeAndCheckCommitData(encodedData, 11, 12);

        assertEq(decodedLastBatch.batchNumber, 10);
        assertEq(decodedNewBatches.length, 2);
        assertEq(decodedNewBatches[0].batchNumber, 11);
        assertEq(decodedNewBatches[1].batchNumber, 12);
    }

    function test_decodeAndCheckCommitData_singleBatch() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(5);
        CommitBatchInfoZKsyncOS[] memory newBatches = new CommitBatchInfoZKsyncOS[](1);
        newBatches[0] = _createCommitBatchInfoZKsyncOS(6);

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT,
            abi.encode(lastBatch, newBatches)
        );

        (IExecutor.StoredBatchInfo memory decodedLastBatch, CommitBatchInfoZKsyncOS[] memory decodedNewBatches) = this
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
        CommitBatchInfoZKsyncOS[] memory newBatches = new CommitBatchInfoZKsyncOS[](1);
        newBatches[0] = _createCommitBatchInfoZKsyncOS(11);

        bytes memory encodedData = abi.encodePacked(unsupportedVersion, abi.encode(lastBatch, newBatches));

        vm.expectRevert(abi.encodeWithSelector(UnsupportedCommitBatchEncoding.selector, unsupportedVersion));
        this.externalDecodeAndCheckCommitData(encodedData, 11, 11);
    }

    /// @notice The retired EraVM commit encoding byte must stay rejected, never silently decoded.
    function test_decodeAndCheckCommitData_revertsOnRetiredEraEncoding() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfoZKsyncOS[] memory newBatches = new CommitBatchInfoZKsyncOS[](1);
        newBatches[0] = _createCommitBatchInfoZKsyncOS(11);

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION,
            abi.encode(lastBatch, newBatches)
        );

        vm.expectRevert(
            abi.encodeWithSelector(UnsupportedCommitBatchEncoding.selector, BatchDecoder.SUPPORTED_ENCODING_VERSION)
        );
        this.externalDecodeAndCheckCommitData(encodedData, 11, 11);
    }

    function test_decodeAndCheckCommitData_revertsOnIncorrectBounds() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfoZKsyncOS[] memory newBatches = new CommitBatchInfoZKsyncOS[](2);
        newBatches[0] = _createCommitBatchInfoZKsyncOS(11);
        newBatches[1] = _createCommitBatchInfoZKsyncOS(12);

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT,
            abi.encode(lastBatch, newBatches)
        );

        // Wrong bounds
        vm.expectRevert(abi.encodeWithSelector(IncorrectBatchBounds.selector, 100, 200, 11, 12));
        this.externalDecodeAndCheckCommitData(encodedData, 100, 200);
    }

    function test_decodeAndCheckCommitData_revertsOnEmptyNewBatches() public {
        IExecutor.StoredBatchInfo memory lastBatch = _createStoredBatchInfo(10);
        CommitBatchInfoZKsyncOS[] memory newBatches = new CommitBatchInfoZKsyncOS[](0);

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION_COMMIT,
            abi.encode(lastBatch, newBatches)
        );

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
            BatchDecoder.SUPPORTED_ENCODING_VERSION,
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
            BatchDecoder.SUPPORTED_ENCODING_VERSION,
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
            BatchDecoder.SUPPORTED_ENCODING_VERSION,
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

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE,
            abi.encode(
                BatchDecoder.DecodedExecuteData({
                    batchesData: executeBatches,
                    priorityOpsData: priorityOps,
                    dependencyRoots: dependencyRoots
                })
            )
        );

        BatchDecoder.DecodedExecuteData memory decoded = this.externalDecodeAndCheckExecuteData(encodedData, 11, 12);

        assertEq(decoded.batchesData.length, 2);
        assertEq(decoded.batchesData[0].batchNumber, 11);
        assertEq(decoded.batchesData[1].batchNumber, 12);
        assertEq(decoded.priorityOpsData.length, 2);
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

        bytes memory encodedData = abi.encodePacked(
            unsupportedVersion,
            abi.encode(
                BatchDecoder.DecodedExecuteData({
                    batchesData: executeBatches,
                    priorityOpsData: priorityOps,
                    dependencyRoots: dependencyRoots
                })
            )
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

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE,
            abi.encode(
                BatchDecoder.DecodedExecuteData({
                    batchesData: executeBatches,
                    priorityOpsData: priorityOps,
                    dependencyRoots: dependencyRoots
                })
            )
        );

        vm.expectRevert(abi.encodeWithSelector(IncorrectBatchBounds.selector, 100, 200, 11, 12));
        this.externalDecodeAndCheckExecuteData(encodedData, 100, 200);
    }

    function test_decodeAndCheckExecuteData_revertsOnEmptyExecuteBatches() public {
        IExecutor.StoredBatchInfo[] memory executeBatches = new IExecutor.StoredBatchInfo[](0);
        PriorityOpsBatchInfo[] memory priorityOps = new PriorityOpsBatchInfo[](0);
        InteropRoot[][] memory dependencyRoots = new InteropRoot[][](0);

        bytes memory encodedData = abi.encodePacked(
            BatchDecoder.SUPPORTED_ENCODING_VERSION_EXECUTE,
            abi.encode(
                BatchDecoder.DecodedExecuteData({
                    batchesData: executeBatches,
                    priorityOpsData: priorityOps,
                    dependencyRoots: dependencyRoots
                })
            )
        );

        vm.expectRevert(EmptyData.selector);
        this.externalDecodeAndCheckExecuteData(encodedData, 1, 1);
    }

    // ============ External Wrappers (for calldata) ============

    function externalDecodeAndCheckCommitData(
        bytes calldata _commitData,
        uint256 _processBatchFrom,
        uint256 _processBatchTo
    ) external pure returns (IExecutor.StoredBatchInfo memory, CommitBatchInfoZKsyncOS[] memory) {
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
    ) external pure returns (BatchDecoder.DecodedExecuteData memory) {
        return BatchDecoder.decodeAndCheckExecuteData(_executeData, _processBatchFrom, _processBatchTo);
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
                commitment: bytes32(0)
            });
    }

    function _createCommitBatchInfoZKsyncOS(uint64 batchNumber) internal pure returns (CommitBatchInfoZKsyncOS memory) {
        return
            CommitBatchInfoZKsyncOS({
                batchNumber: batchNumber,
                newStateCommitment: keccak256(abi.encodePacked(batchNumber)),
                numberOfLayer1Txs: 0,
                numberOfLayer2Txs: 0,
                priorityOperationsHash: bytes32(0),
                dependencyRootsRollingHash: bytes32(0),
                l2LogsTreeRoot: bytes32(0),
                daCommitmentScheme: L2DACommitmentScheme.BLOBS_AND_PUBDATA_KECCAK256,
                daCommitment: bytes32(0),
                firstBlockTimestamp: uint64(batchNumber) * 100,
                firstBlockNumber: uint64(batchNumber) * 10,
                lastBlockTimestamp: uint64(batchNumber) * 100 + 1,
                lastBlockNumber: uint64(batchNumber) * 10 + 1,
                chainId: 9,
                operatorDAInput: "",
                slChainId: 1
            });
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {RollupL1DAValidator} from "../contracts/RollupL1DAValidator.sol";

contract DummyRollupL1DAValidator is RollupL1DAValidator {

    function getPublishedBlobCommitment(uint256 _index, bytes calldata _commitment) external view returns (bytes32) {
        return _getPublishedBlobCommitment(_index, _commitment);
    }

    function processBlobDA(
        uint256 _blobsProvided,
        uint256 _maxBlobsSupported,
        bytes calldata _operatorDAInput
    ) external view returns (bytes32[] memory blobsCommitments) {
        return _processBlobDA(_blobsProvided, _maxBlobsSupported, _operatorDAInput);
    }

    function pointEvaluationPrecompile(
        bytes32 _versionedHash,
        bytes32 _openingPoint,
        bytes calldata _openingValueCommitmentProof
    ) external view {
        return _pointEvaluationPrecompile(_versionedHash, _openingPoint, _openingValueCommitmentProof);
    }

    function getBlobVersionedHash(uint256 _index) external view virtual returns (bytes32 versionedHash) {
        return _getBlobVersionedHash(_index);
    }

    function dummyPublishBlobs(bytes32 blobCommitment) external {
        publishedBlobCommitments[blobCommitment] = true;
    }
}
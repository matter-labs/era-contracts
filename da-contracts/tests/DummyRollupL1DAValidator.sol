// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;
import {Vm as vm} from "lib/forge-std/src/Vm.sol";
import {RollupL1DAValidator} from "../contracts/RollupL1DAValidator.sol";
import {PubdataCommitmentsEmpty, InvalidPubdataCommitmentsSize, BlobHashCommitmentError, EmptyBlobVersionHash, NonEmptyBlobVersionHash, PointEvalCallFailed, PointEvalFailed} from "../contracts/DAContractsErrors.sol";
import {PubdataSource, BLS_MODULUS, PUBDATA_COMMITMENT_SIZE, PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET, PUBDATA_COMMITMENT_COMMITMENT_OFFSET, BLOB_DA_INPUT_SIZE, POINT_EVALUATION_PRECOMPILE_ADDR} from "../contracts/DAUtils.sol";

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

    function dummyPublishBlobs(bytes32 blobCommitment) public {
        publishedBlobCommitments[blobCommitment] = true;
    }

    function dummyPublishBlobsTest(bytes calldata _pubdataCommitments) external {
        if (_pubdataCommitments.length == 0) {
            revert PubdataCommitmentsEmpty();
        }
        if (_pubdataCommitments.length % PUBDATA_COMMITMENT_SIZE != 0) {
            revert InvalidPubdataCommitmentsSize();
        }

        uint256 versionedHashIndex = 0;
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _pubdataCommitments.length; i += PUBDATA_COMMITMENT_SIZE) {
            bytes32 blobCommitment = dummyGetPublishedBlobCommitment(
                versionedHashIndex,
                _pubdataCommitments[i:i + PUBDATA_COMMITMENT_SIZE]
            );
            publishedBlobCommitments[blobCommitment] = true;
            ++versionedHashIndex;
        }
    }

    function dummyGetPublishedBlobCommitment(uint256 _index, bytes calldata _commitment) public returns (bytes32) {
        bytes32 blobVersionedHash = _getBlobVersionedHash(_index);

        if (blobVersionedHash == bytes32(0)) {
            revert EmptyBlobVersionHash(_index);
        }

        // First 16 bytes is the opening point. While we get the point as 16 bytes, the point evaluation precompile
        // requires it to be 32 bytes. The blob commitment must use the opening point as 16 bytes though.

        blobVersionedHash = 0x01cf45213dd7b4716864d378f3c6d861467987e4d94b7f79a1f814a697e38637;
        bytes32 blobClaimedValue = bytes32(
            uint256(uint128(bytes16(_commitment[PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET + 16:PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET + 32])))
        );

        dummyPublishBlobs(blobVersionedHash);

        dummyPointEvaluationPrecompile(
            blobVersionedHash,
            _commitment[:PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET + 16],
            blobClaimedValue,
            _commitment[PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET + 32:PUBDATA_COMMITMENT_SIZE]
        );

        // Take the hash of the versioned hash || opening point || claimed value
        return keccak256(abi.encodePacked(blobVersionedHash, _commitment[:PUBDATA_COMMITMENT_COMMITMENT_OFFSET]));
    }

    function dummyPointEvaluationPrecompile(
        bytes32 _versionedHash,
        bytes calldata _openingPoint,
        bytes32 _blobClaimedValue,
        bytes calldata _openingValueCommitmentProof
    ) internal {
        bytes memory precompileInput = abi.encodePacked(_versionedHash, _openingPoint, _blobClaimedValue, _openingValueCommitmentProof);

        (bool success, bytes memory data) = POINT_EVALUATION_PRECOMPILE_ADDR.staticcall(precompileInput);

        // We verify that the point evaluation precompile call was successful by testing the latter 32 bytes of the
        // response is equal to BLS_MODULUS as defined in https://eips.ethereum.org/EIPS/eip-4844#point-evaluation-precompile
        if (!success) {
            revert PointEvalCallFailed(precompileInput);
        }
        (, uint256 result) = abi.decode(data, (uint256, uint256));
        if (result != BLS_MODULUS) {
            revert PointEvalFailed(abi.encode(result));
        }
    }

    function mockPointEvaluationPrecompile( 
        bool success,
        bytes calldata data,
        bytes calldata precompileInput
    ) external {
        if (!success) {
            revert PointEvalCallFailed(precompileInput);
        }
        (, uint256 result) = abi.decode(data, (uint256, uint256));
        if (result != BLS_MODULUS) {
            revert PointEvalFailed(abi.encode(result));
        }
    }
}
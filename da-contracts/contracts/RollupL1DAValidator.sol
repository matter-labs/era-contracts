// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1DAValidator, L1DAValidatorOutput} from "./IL1DAValidator.sol";

import {CalldataDA} from "./CalldataDA.sol";

import {PubdataSource, BLS_MODULUS, PUBDATA_COMMITMENT_SIZE, PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET, PUBDATA_COMMITMENT_COMMITMENT_OFFSET, BLOB_DA_INPUT_SIZE, POINT_EVALUATION_PRECOMPILE_ADDR} from "./DAUtils.sol";

import {InvalidPubdataSource, PubdataCommitmentsEmpty, InvalidPubdataCommitmentsSize, BlobHashCommitmentError, EmptyBlobVersionHash, NonEmptyBlobVersionHash, PointEvalCallFailed, PointEvalFailed, BlobCommitmentNotPublished} from "./DAContractsErrors.sol";

uint256 constant BLOBS_SUPPORTED = 6;

/// @dev The number of blocks within each we allow blob to be used for DA.
/// On Ethereum blobs expire within 4096 epochs, i.e. 4096 * 32 blocks. We reserve
/// half of the time in order to ensure reader's ability to read the blob's content.
uint256 constant BLOB_EXPIRATION_BLOCKS = (4096 * 32) / 2;

contract RollupL1DAValidator is IL1DAValidator, CalldataDA {
    /// @notice The published blob commitments. Note, that the correctness of blob commitment with relation to the linear hash
    /// is *not* checked in this contract, but is expected to be checked at the verification stage of the ZK contract.
    mapping(bytes32 blobCommitment => uint256 blockOfPublishing) public publishedBlobCommitments;

    /// @notice Publishes certain blobs, marking commitments to them as published.
    /// @param _pubdataCommitments The commitments to the blobs to be published.
    /// `_pubdataCommitments` is a packed list of commitments of the following format:
    /// opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes)
    function publishBlobs(bytes calldata _pubdataCommitments) external {
        if (_pubdataCommitments.length == 0) {
            revert PubdataCommitmentsEmpty();
        }
        if (_pubdataCommitments.length % PUBDATA_COMMITMENT_SIZE != 0) {
            revert InvalidPubdataCommitmentsSize();
        }

        uint256 versionedHashIndex = 0;
        // solhint-disable-next-line gas-length-in-loops
        for (uint256 i = 0; i < _pubdataCommitments.length; i += PUBDATA_COMMITMENT_SIZE) {
            bytes32 blobCommitment = _getPublishedBlobCommitment(
                versionedHashIndex,
                _pubdataCommitments[i:i + PUBDATA_COMMITMENT_SIZE]
            );
            publishedBlobCommitments[blobCommitment] = block.number;
            ++versionedHashIndex;
        }
    }

    function isBlobAvailable(bytes32 _blobCommitment) public view returns (bool) {
        uint256 blockOfPublishing = publishedBlobCommitments[_blobCommitment];

        // While `block.number` on all used L1 networks is much higher than `BLOB_EXPIRATION_BLOCKS`,
        // we still check that `blockOfPublishing > 0` just in case.
        return blockOfPublishing > 0 && block.number - blockOfPublishing <= BLOB_EXPIRATION_BLOCKS;
    }

    /// @inheritdoc IL1DAValidator
    function checkDA(
        uint256, // _chainId
        uint256, // _batchNumber
        bytes32 _l2DAValidatorOutputHash,
        bytes calldata _operatorDAInput,
        uint256 _maxBlobsSupported
    ) external view returns (L1DAValidatorOutput memory output) {
        (
            bytes32 stateDiffHash,
            bytes32 fullPubdataHash,
            bytes32[] memory blobsLinearHashes,
            uint256 blobsProvided,
            bytes calldata l1DaInput
        ) = _processL2RollupDAValidatorOutputHash(_l2DAValidatorOutputHash, _maxBlobsSupported, _operatorDAInput);

        uint8 pubdataSource = uint8(l1DaInput[0]);
        bytes32[] memory blobCommitments;

        if (pubdataSource == uint8(PubdataSource.Blob)) {
            blobCommitments = _processBlobDA(blobsProvided, _maxBlobsSupported, l1DaInput[1:]);
        } else if (pubdataSource == uint8(PubdataSource.Calldata)) {
            (blobCommitments, ) = _processCalldataDA(blobsProvided, fullPubdataHash, _maxBlobsSupported, l1DaInput[1:]);
        } else {
            revert InvalidPubdataSource(pubdataSource);
        }

        // We verify that for each set of blobHash/blobCommitment are either both empty
        // or there are values for both.
        // This is mostly a sanity check and it is not strictly required.
        for (uint256 i = 0; i < _maxBlobsSupported; ++i) {
            if (
                (blobsLinearHashes[i] == bytes32(0) && blobCommitments[i] != bytes32(0)) ||
                (blobsLinearHashes[i] != bytes32(0) && blobCommitments[i] == bytes32(0))
            ) {
                revert BlobHashCommitmentError(i, blobsLinearHashes[i] == bytes32(0), blobCommitments[i] == bytes32(0));
            }
        }

        output.stateDiffHash = stateDiffHash;
        output.blobsLinearHashes = blobsLinearHashes;
        output.blobsOpeningCommitments = blobCommitments;
    }

    /// @notice Generated the blob commitemnt to be used in the cryptographic proof by calling the point evaluation precompile.
    /// @param _index The index of the blob in this transaction.
    /// @param _commitment The packed: opening point (16 bytes) || claimed value (32 bytes) || commitment (48 bytes) || proof (48 bytes)) = 144 bytes
    /// @return The commitment to be used in the cryptographic proof.
    function _getPublishedBlobCommitment(uint256 _index, bytes calldata _commitment) internal view returns (bytes32) {
        bytes32 blobVersionedHash = _getBlobVersionedHash(_index);

        if (blobVersionedHash == bytes32(0)) {
            revert EmptyBlobVersionHash(_index);
        }

        // First 16 bytes is the opening point. While we get the point as 16 bytes, the point evaluation precompile
        // requires it to be 32 bytes. The blob commitment must use the opening point as 16 bytes though.
        bytes32 openingPoint = bytes32(
            uint256(uint128(bytes16(_commitment[:PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET])))
        );

        _pointEvaluationPrecompile(
            blobVersionedHash,
            openingPoint,
            _commitment[PUBDATA_COMMITMENT_CLAIMED_VALUE_OFFSET:PUBDATA_COMMITMENT_SIZE]
        );

        // Take the hash of the versioned hash || opening point || claimed value
        return keccak256(abi.encodePacked(blobVersionedHash, _commitment[:PUBDATA_COMMITMENT_COMMITMENT_OFFSET]));
    }

    /// @notice Verify that the blob DA was correctly provided.
    /// @param _blobsProvided The number of blobs provided.
    /// @param _maxBlobsSupported Maximum number of blobs supported.
    /// @param _operatorDAInput Input used to verify that the blobs contain the data we expect.
    function _processBlobDA(
        uint256 _blobsProvided,
        uint256 _maxBlobsSupported,
        bytes calldata _operatorDAInput
    ) internal view returns (bytes32[] memory blobsCommitments) {
        blobsCommitments = new bytes32[](_maxBlobsSupported);

        // For blobs we expect to receive the commitments in the following format:
        // 144 bytes for commitment data
        // 32 bytes for the prepublished commitment. If it is non-zero, it means that it is expected that
        // such commitment was published before. Otherwise, it is expected that it is published in this transaction
        if (_operatorDAInput.length != _blobsProvided * BLOB_DA_INPUT_SIZE) {
            revert InvalidPubdataCommitmentsSize();
        }

        uint256 versionedHashIndex = 0;

        // we iterate over the `_operatorDAInput`, while advancing the pointer by `BLOB_DA_INPUT_SIZE` each time
        for (uint256 i = 0; i < _blobsProvided; ++i) {
            bytes calldata commitmentData = _operatorDAInput[:PUBDATA_COMMITMENT_SIZE];
            bytes32 prepublishedCommitment = bytes32(_operatorDAInput[PUBDATA_COMMITMENT_SIZE:BLOB_DA_INPUT_SIZE]);

            if (prepublishedCommitment != bytes32(0)) {
                // We double check that this commitment has indeed been published.
                // If that is the case, we do not care about the actual underlying data.
                if (!isBlobAvailable(prepublishedCommitment)) {
                    revert BlobCommitmentNotPublished();
                }
                blobsCommitments[i] = prepublishedCommitment;
            } else {
                blobsCommitments[i] = _getPublishedBlobCommitment(versionedHashIndex, commitmentData);
                ++versionedHashIndex;
            }

            // Advance the pointer
            _operatorDAInput = _operatorDAInput[BLOB_DA_INPUT_SIZE:];
        }

        // This check is required because we want to ensure that there aren't any extra blobs trying to be published.
        // Calling the BLOBHASH opcode with an index > # blobs - 1 yields bytes32(0)
        bytes32 versionedHash = _getBlobVersionedHash(versionedHashIndex);
        if (versionedHash != bytes32(0)) {
            revert NonEmptyBlobVersionHash(versionedHashIndex);
        }
    }

    /// @notice Calls the point evaluation precompile and verifies the output
    /// Verify p(z) = y given commitment that corresponds to the polynomial p(x) and a KZG proof.
    /// Also verify that the provided commitment matches the provided versioned_hash.
    ///
    function _pointEvaluationPrecompile(
        bytes32 _versionedHash,
        bytes32 _openingPoint,
        bytes calldata _openingValueCommitmentProof
    ) internal view {
        bytes memory precompileInput = abi.encodePacked(_versionedHash, _openingPoint, _openingValueCommitmentProof);

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

    function _getBlobVersionedHash(uint256 _index) internal view virtual returns (bytes32 versionedHash) {
        assembly {
            versionedHash := blobhash(_index)
        }
    }
}

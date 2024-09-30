// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x53dee67b
error PubdataCommitmentsEmpty();
// 0x7734c31a
error PubdataCommitmentsTooBig();
// 0x53e6d04d
error InvalidPubdataCommitmentsSize();
// 0xafd53e2f
error BlobHashCommitmentError(uint256 index, bool blobHashEmpty, bool blobCommitmentEmpty);
// 0xfc7ab1d3
error EmptyBlobVersionHash(uint256 index);
// 0x92290acc
error NonEmptyBlobVersionHash(uint256 index);
// 0x8d5851de
error PointEvalCallFailed(bytes);
// 0x4daa985d
error PointEvalFailed(bytes);

error OperatorDAInputLengthTooSmall(uint256 operatorDAInputLength, uint256 blobDataOffset);

error InvalidNumberOfBlobs(uint256 blobsProvided, uint256 maxBlobsSupported);

error InvalidBlobsHashes(uint256 operatorDAInputLength, uint256 blobsProvided);

error InvalidL2DAOutputHash();

error OneBlobWithCalldata();

error PubdataInputTooSmall(uint256 pubdataInputLength, uint256 blobCommitmentSize);

error PubdataLengthTooBig(uint256 pubdataLength, uint256 blobSizeBytes);

error InvalidPubdataHash(bytes32 fullPubdataHash, bytes32 pubdata);

error BlobCommitmentNotPublished();

error ValL1DAWrongInputLength(uint256 operatorDAInputLength, uint256 expected);

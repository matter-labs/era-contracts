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

error OperatorDAInputLengthTooSmall();

error InvalidNumberOfBlobs();

error InvalidBlobsHashes();

error InvalidL2DAOutputHash();

error OneBlobWithCalldata();

error PubdataInputTooSmall();

error PubdataLengthTooBig();

error InvalidPubdataHash();

error BlobCommitmentNotPublished();

error ValL1DAWrongInputLength();

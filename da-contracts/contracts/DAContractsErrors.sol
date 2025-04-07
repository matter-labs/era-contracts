// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x53dee67b
error PubdataCommitmentsEmpty();
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

// 0x885ae069
error OperatorDAInputTooSmall(uint256 operatorDAInputLength, uint256 minAllowedLength);

// 0xbeb96791
error InvalidNumberOfBlobs(uint256 blobsProvided, uint256 maxBlobsSupported);

// 0xd2531c15
error InvalidL2DAOutputHash(bytes32 l2DAValidatorOutputHash);

// 0x04e05fd1
error OnlyOneBlobWithCalldataAllowed();

// 0x2dc9747d
error PubdataInputTooSmall(uint256 pubdataInputLength, uint256 totalBlobsCommitmentSize);

// 0x9044dff9
error PubdataLengthTooBig(uint256 pubdataLength, uint256 totalBlobSizeBytes);

// 0x5513177c
error InvalidPubdataHash(bytes32 fullPubdataHash, bytes32 providedPubdataHash);

// 0xc771423e
error BlobCommitmentNotPublished();

// 0x5717f940
error InvalidPubdataSource(uint8 pubdataSource);

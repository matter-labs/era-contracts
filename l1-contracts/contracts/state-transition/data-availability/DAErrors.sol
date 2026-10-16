// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0xc771423e
error BlobCommitmentNotPublished();
// 0xafd53e2f
error BlobHashCommitmentError(uint256 index, bool blobHashEmpty, bool blobCommitmentEmpty);
// 0x783ab813
error BlobNotPublished();
// 0xfc7ab1d3
error EmptyBlobVersionHash(uint256 index);
// 0xb43e4800
error InvalidAttestationProof();
// 0x6122198f
error InvalidBlobsDAInputLength(uint256 pubdataInputLength);
// 0x8b003a9d
error InvalidBlobsPublished(bytes32 publishedHash, bytes32 expectedHash);
// 0x53e6d04d
error InvalidPubdataCommitmentsSize();
// 0x79af508b
error InvalidValidatorOutputHash();
// 0x92290acc
error NonEmptyBlobVersionHash(uint256 index);
// 0x8d5851de
error PointEvalCallFailed(bytes);
// 0x4daa985d
error PointEvalFailed(bytes);
// 0x53dee67b
error PubdataCommitmentsEmpty();

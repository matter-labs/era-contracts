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

// 0xf4a3e629
error OperatorDAInputLengthTooSmall(uint256 operatorDAInputLength, uint256 blobDataOffset);

// 0xbeb96791
error InvalidNumberOfBlobs(uint256 blobsProvided, uint256 maxBlobsSupported);

// 0xcd384e46
error InvalidBlobsHashes(uint256 operatorDAInputLength, uint256 blobsProvided);

// 0xe9e79528
error InvalidL2DAOutputHash();

// 0x3db6e664
error OneBlobWithCalldata();

// 0x2dc9747d
error PubdataInputTooSmall(uint256 pubdataInputLength, uint256 blobCommitmentSize);

// 0x9044dff9
error PubdataLengthTooBig(uint256 pubdataLength, uint256 blobSizeBytes);

// 0x5513177c
error InvalidPubdataHash(bytes32 fullPubdataHash, bytes32 pubdata);

// 0xc771423e
error BlobCommitmentNotPublished();

// 0x5717f940
error InvalidPubdataSource(uint8 pubdataSource);
// 0x52595598
error ValL1DAWrongInputLength(uint256 inputLength, uint256 expectedLength);

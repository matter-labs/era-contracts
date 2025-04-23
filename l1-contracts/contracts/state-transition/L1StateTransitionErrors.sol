// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0x2e89f517
error L1DAValidatorAddressIsZero();

// 0x944bc075
error L2DAValidatorAddressIsZero();

// 0xca1c3cbc
error AlreadyMigrated();

// 0xf05c64c6
error NotChainAdmin(address prevMsgSender, address admin);

// 0xc59d372c
error ProtocolVersionNotUpToDate(uint256 currentProtocolVersion, uint256 protocolVersion);

// 0xedae13f3
error ExecutedIsNotConsistentWithVerified(uint256 batchesExecuted, uint256 batchesVerified);

// 0x712d02d2
error VerifiedIsNotConsistentWithCommitted(uint256 batchesVerified, uint256 batchesCommitted);

// 0xfb1a3b59
error InvalidNumberOfBatchHashes(uint256 batchHashesLength, uint256 expected);

// 0xa840274f
error PriorityQueueNotReady();

// 0x79274f04
error UnsupportedProofMetadataVersion(uint256 metadataVersion);

// 0xa969e486
error LocalRootIsZero();

// 0xbdaf7d42
error LocalRootMustBeZero();

// 0xd0266e26
error NotSettlementLayer();

// 0x32ddf9a2
error NotHyperchain();

// 0x2237c426
error MismatchL2DAValidator();

// 0x2c01a4af
error MismatchNumberOfLayer1Txs(uint256 numberOfLayer1Txs, uint256 expectedLength);

// 0xfbd630b8
error InvalidBatchesDataLength(uint256 batchesDataLength, uint256 priorityOpsDataLength);

// 0x55008233
error PriorityOpsDataLeftPathLengthIsNotZero();

// 0x8be936a9
error PriorityOpsDataRightPathLengthIsNotZero();

// 0x99d44739
error PriorityOpsDataItemHashesLengthIsNotZero();

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

// 0x5717f940
error InvalidPubdataSource(uint8 pubdataSource);

// 0x125d99b0
error BlobHashBlobCommitmentMismatchValue();

// 0x7fbff2dd
error L1DAValidatorInvalidSender(address msgSender);

// 0xc06789fa
error InvalidCommitment();

// 0xc866ff2c
error InitialForceDeploymentMismatch(bytes32 forceDeploymentHash, bytes32 initialForceDeploymentHash);

// 0xb325f767
error AdminZero();

// 0x681150be
error OutdatedProtocolVersion(uint256 protocolVersion, uint256 currentProtocolVersion);

// 0x87470e36
error NotL1(uint256 blockChainId);

// 0x90f67ecf
error InvalidStartIndex(uint256 treeStartIndex, uint256 commitmentStartIndex);

// 0x0f67bc0a
error InvalidUnprocessedIndex(uint256 treeUnprocessedIndex, uint256 commitmentUnprocessedIndex);

// 0x30043900
error InvalidNextLeafIndex(uint256 treeNextLeafIndex, uint256 commitmentNextLeafIndex);

// 0xf9ba09d6
error NotAllBatchesExecuted();

// 0x9b53b101
error NotHistoricalRoot();

// 0xc02d3ee3
error ContractNotDeployed();

// 0xd7b2559b
error NotMigrated();

// 0x52595598
error ValL1DAWrongInputLength(uint256 inputLength, uint256 expectedLength);

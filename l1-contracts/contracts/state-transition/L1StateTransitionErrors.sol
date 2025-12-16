// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

// 0xb325f767
error AdminZero();
// 0xca1c3cbc
error AlreadyMigrated();
// 0x125d99b0
error BlobHashBlobCommitmentMismatchValue();
// 0xafda12bf
error CommitBasedInteropNotSupported();
// 0xc02d3ee3
error ContractNotDeployed();
// 0xdf2c5fa5
error DependencyRootsRollingHashMismatch(bytes32 _expected, bytes32 _actual);
// 0xacf542ab
error DepositsAlreadyPaused();
// 0xa4d3098c
error DepositsNotPaused();
// 0xdeeb6943
error DepositsPaused();
// 0xedae13f3
error ExecutedIsNotConsistentWithVerified(uint256 batchesExecuted, uint256 batchesVerified);
// 0xc866ff2c
error InitialForceDeploymentMismatch(bytes32 forceDeploymentHash, bytes32 initialForceDeploymentHash);
// 0xfbd630b8
error InvalidBatchesDataLength(uint256 batchesDataLength, uint256 priorityOpsDataLength);
// 0xc06789fa
error InvalidCommitment();
// 0xd2531c15
error InvalidL2DAOutputHash(bytes32 l2DAValidatorOutputHash);
// 0x30043900
error InvalidNextLeafIndex(uint256 treeNextLeafIndex, uint256 commitmentNextLeafIndex);
// 0xfb1a3b59
error InvalidNumberOfBatchHashes(uint256 batchHashesLength, uint256 expected);
// 0xbeb96791
error InvalidNumberOfBlobs(uint256 blobsProvided, uint256 maxBlobsSupported);
// 0x5513177c
error InvalidPubdataHash(bytes32 fullPubdataHash, bytes32 providedPubdataHash);
// 0x5717f940
error InvalidPubdataSource(uint8 pubdataSource);
// 0x90f67ecf
error InvalidStartIndex(uint256 treeStartIndex, uint256 commitmentStartIndex);
// 0x0f67bc0a
error InvalidUnprocessedIndex(uint256 treeUnprocessedIndex, uint256 commitmentUnprocessedIndex);
// 0x2e89f517
error L1DAValidatorAddressIsZero();
// 0x7fbff2dd
error L1DAValidatorInvalidSender(address msgSender);
// 0xa969e486
error LocalRootIsZero();
// 0xbdaf7d42
error LocalRootMustBeZero();
// 0x9b5f85eb
error MessageRootIsZero();
// 0xf148c8da
error MigrationInProgress();
// 0x32fff278
error MismatchL2DACommitmentScheme(uint256 operatorProvidedScheme, uint256 expectedScheme);
// 0x2c01a4af
error MismatchNumberOfLayer1Txs(uint256 numberOfLayer1Txs, uint256 expectedLength);
// 0xf9ba09d6
error NotAllBatchesExecuted();
// 0xf05c64c6
error NotChainAdmin(address prevMsgSender, address admin);
// 0x8fd63d21
error NotEraChain();
// 0xa7050bf6
error NotHistoricalRoot(bytes32);
// 0x32ddf9a2
error NotHyperchain();
// 0x87470e36
error NotL1(uint256 blockChainId);
// 0xd7b2559b
error NotMigrated();
// 0xd0266e26
error NotSettlementLayer();
// 0x04e05fd1
error OnlyOneBlobWithCalldataAllowed();
// 0x885ae069
error OperatorDAInputTooSmall(uint256 operatorDAInputLength, uint256 minAllowedLength);
// 0x681150be
error OutdatedProtocolVersion(uint256 protocolVersion, uint256 currentProtocolVersion);
// 0xfe26193e
error PriorityQueueNotFullyProcessed();
// 0xc59d372c
error ProtocolVersionNotUpToDate(uint256 currentProtocolVersion, uint256 protocolVersion);
// 0x2dc9747d
error PubdataInputTooSmall(uint256 pubdataInputLength, uint256 totalBlobsCommitmentSize);
// 0x9044dff9
error PubdataLengthTooBig(uint256 pubdataLength, uint256 totalBlobSizeBytes);
// 0x89935a14
error SettlementLayerChainIdMismatch();
// 0x97f58c80
error TotalPriorityTxsIsZero();
// 0x0baf1d48
error UnknownVerifierVersion();
// 0x79274f04
error UnsupportedProofMetadataVersion(uint256 metadataVersion);
// 0x52595598
error ValL1DAWrongInputLength(uint256 inputLength, uint256 expectedLength);
// 0x712d02d2
error VerifiedIsNotConsistentWithCommitted(uint256 batchesVerified, uint256 batchesCommitted);

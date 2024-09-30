// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

error L1DAValidatorAddressIsZero();

error L2DAValidatorAddressIsZero();

error AlreadyMigrated();

error NotChainAdmin(address prevMsgSender, address admin);

error ProtocolVersionNotUpToDate(uint256 currentProtocolVersion, uint256 protocolVersion);

error ExecutedIsNotConsistentWithVerified(uint256 batchesExecuted, uint256 batchesVerified);

error VerifiedIsNotConsistentWithCommitted(uint256 batchesVerified, uint256 batchesCommitted);

error InvalidNumberOfBatchHashes(uint256 batchHashesLength, uint256 expected);

error PriorityQueueNotReady();

error VerifiedIsNotConsistentWithExecuted(uint256 totalBatchesExecuted, uint256 totalBatchesVerified);

error UnsupportedProofMetadataVersion(uint256 metadataVersion);

error LocalRootIsZero();

error LocalRootMustBeZero();

error MailboxWrongStateTransitionManager();

error NotSettlementLayers();

error NotHyperchain();

error MismatchL2DAValidator();

error MismatchNumberOfLayer1Txs(uint256 numberOfLayer1Txs, uint256 expectedLength);

error InvalidBatchesDataLength(uint256 batchesDataLength, uint256 priorityOpsDataLength);

error PriorityOpsDataLeftPathLengthIsNotZero();

error PriorityOpsDataRightPathLengthIsNotZero();

error PriorityOpsDataItemHashesLengthIsNotZero();

error OperatorDAInputTooSmall(uint256 operatorDAInputLength, uint256 BlobDataOffset);

error InvalidNumberOfBlobs(uint256 blobsProvided, uint256 maxBlobsSupported);

error InvalidBlobsHashes(uint256 operatorDAInputLength, uint256 minNumberOfBlobHashes);

error InvalidL2DAOutputHash(bytes32 l2DAValidatorOutputHash);

error OnlyOneBlobWithCalldata();

error PubdataTooSmall(uint256 pubdataInputLength, uint256 blobCommitmentSize);

error PubdataTooLong(uint256 pubdataLength, uint256 blobSizeBytes);

error InvalidPubdataHash();

error BlobHashBlobCommitmentMismatchValue();

error L1DAValidatorInvalidSender(address msgSender);

error RootMismatch();

error InvalidCommitment();

error InitialForceDeploymentMismatch(bytes32 forceDeploymentHash, bytes32 initialForceDeploymentHash);

error ZeroChainId();

error SyncLayerNotRegistered();

error AdminZero();

error OutdatedProtocolVersion(uint256 protocolVersion, uint256 currentProtocolVersion);

error ChainWasMigrated();

error NotL1(uint256 blockChainId);

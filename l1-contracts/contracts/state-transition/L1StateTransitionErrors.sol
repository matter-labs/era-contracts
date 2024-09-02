// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

error L1DAValidatorAddressIsZero();

error L2DAValidatorAddressIsZero();

error AlreadyMigrated();

error NotChainAdmin();

error ProtocolVersionNotUpToDate();

error ExecutedIsNotConsistentWithVerified();

error VerifiedIsNotConsistentWithCommitted();

error InvalidNumberOfBatchHashes();

error PriorityQueueNotReady();

error VerifiedIsNotConsistentWithExecuted();

error UnsupportedProofMetadataVersion();

error LocalRootIsZero();

error LocalRootMustBeZero();

error MailboxWrongStateTransitionManager();

error NotSettlementLayers();

error NotHyperchain();

error MissmatchL2DAValidator();

error InvalidExpectedSystemContractUpgradeTXHashKey();

error MissmatchNumberOfLayer1Txs();

error InvalidBatchesDataLength();

error PriorityOpsDataLeftPathLengthIsNotZero();

error PriorityOpsDataRightPathLengthIsNotZero();

error PriorityOpsDataItemHashesLengthIsNotZero();

error OperatorDAInputTooSmall();

error InvalidNumberOfBlobs();

error InvalidBlobsHashes();

error InvalidL2DAOutputHash();

error OnlyOneBlobWithCalldata();

error PubdataTooSmall();

error PubdataTooLong();

error InvalidPubdataHash();

error BlobHashBlobCommitmentMissmatchValue();

error L1DAValidatorInvalidSender();

error RootMismatch();

error InvalidCommitment();

error InitialForceDeploymentMismatch();

error BadChainId();

error SyncLayerNotRegistered();

error AdminZero();

error OutdatedProtocolVersion();
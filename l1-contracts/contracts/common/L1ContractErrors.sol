// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {L2DACommitmentScheme} from "./Config.sol";

// 0x5ecf2d7a
error AccessToFallbackDenied(address target, address invoker);
// 0x3995f750
error AccessToFunctionDenied(address target, bytes4 selector, address invoker);
// 0x0dfb42bf
error AddressAlreadySet(address addr);
// 0x86bb51b8
error AddressHasNoCode(address);
// 0x1f73225f
error AddressMismatch(address expected, address supplied);
// 0x42573d7a
error AddressNotZero();
// 0xb577eb6c
error AlreadyDangerousContract(address);
// 0x2a5989a0
error AlreadyPermanentRollup();
// 0x0bfcef28
error AlreadyWhitelisted(address);
// 0x5e85ae73
error AmountMustBeGreaterThanZero();
// 0x76fc80ad
error AssetDeploymentTrackerNotSet(bytes32 assetId);
// 0xfde974f4
error AssetHandlerDoesNotExist(bytes32 assetId);
// 0x64107968
error AssetHandlerNotRegistered(bytes32 assetId);
// 0xfe919e28
error AssetIdAlreadyRegistered();
// 0x1294e9e1
error AssetIdMismatch(bytes32 expected, bytes32 supplied);
// 0xda72d995
error AssetIdNotRegistered(bytes32 assetId);
// 0x04a0b7e9
error AssetIdNotSupported(bytes32 assetId);
// 0x9b821ed7
error BadTransferDataLength();
// 0x6ef9a972
error BaseTokenGasPriceDenominatorNotSet();
// 0x764c57db
error BaseTokenHolderAlreadyInitialized();
// 0xd3cd4bd2
error BaseTokenHolderMintFailed();
// 0x8361ff70
error BaseTokenNativeToThisChain();
// 0xe3ec2bc9
error BaseTokenTransferFailed();
// 0x55ad3fd3
error BatchHashMismatch(bytes32 expected, bytes32 actual);
// 0xbd4455ff
error BatchNumberMismatch(uint256 expectedBatchNumber, uint256 providedBatchNumber);
// 0x41c329f7
error BatchTimestampGreaterThanLastL2BlockTimestamp();
// 0x63506488
error BootstrapAlreadyExecuted();
// 0x81ded943
error BootstrapAuthorityNotHeld(address target, address actualOwner);
// 0xb772460f
error BootstrapExecutorNotBound(address executor, address expectedTarget, address actualTarget);
// 0x447aee1e
error BootstrapNotYetExecuted();
// 0x24c8e294
error BootstrapReleaseNotInstalled(address expected, address actual);
// 0x6cf12312
error BridgeHubAlreadyRegistered();
// 0xdb538614
error BridgeMintNotImplemented();
// 0xaa5f6180
error BurningNativeWETHNotSupported();
// 0x25d8333c
error CallerNotTimerAdmin();
// 0x3331e9c0
error CallNotAllowed(bytes call);
// 0xe85392f9
error CanOnlyProcessOneBatch();
// 0x00c6ead2
error CantExecuteUnprovenBatches();
// 0xe18cb383
error CantRevertExecutedBatch();
// 0x78d2ed02
error ChainAlreadyLive();
// 0xd054a77e
error ChainBalanceMustBeZeroBeforeMigration(uint256 chainId, bytes32 assetId, uint256 chainBalance);
// 0x24591d89
error ChainIdAlreadyExists();
// 0x717a1656
error ChainIdCantBeCurrentChain();
// 0x6b617b38
error ChainIdIsHardcoded();
// 0xa179f8c9
error ChainIdMismatch();
// 0x23f3c357
error ChainIdNotRegistered(uint256 chainId);
// 0x8f620a06
error ChainIdTooBig();
// 0x41888953
error ChainMigrationsDisabled();
// 0x5e361ef9
error ChainRequiresValidatorsSignaturesForCommit();
// 0x8746f42f
error ConstructorsNotSupported();
// 0xec273439
error CTMAlreadyRegistered();
// 0xc630ef3c
error CTMNotRegistered();
// 0x13df796c
error CutDataForProtocolVersionNotAvailable(uint256 oldProtocolVersion);
// 0x907f8e51
error DeadlineNotYetPassed();
// 0xf2885eb3
error DefaultAdminTransferNotAllowed();
// 0xf7a01e4d
error DelegateCallFailed(bytes returnData);
// 0x0a8ed92c
error DenominatorIsZero();
// 0xb4f54111
error DeployFailed();
// 0x138ee1a3
error DeployingBridgedTokenForNativeToken();
// 0x42bce528
error DepositDoesNotExist(bytes32, bytes32);
// 0xad2fa98e
error DepositExists();
// 0x0e7ee319
error DiamondAlreadyFrozen();
// 0xa7151b9a
error DiamondNotFrozen();
// 0x7138356f
error EmptyAddress();
// 0x2d4d012f
error EmptyAssetId();
// 0x1c25715b
error EmptyBytes32();
// 0x99d8fec9
error EmptyData();
// 0x84286507
error EmptyPrecommitData(uint256 batchNumber);
// 0x456f8f7a
error EmptyProofLength();
// 0x05410cbc
error EmptyPublicInputsLength();
// 0x876e8b23
error EraBytecodeAlreadyPublished(bytes32 bytecodeHash);
// 0x61733a89
error EVMBytecodeAlreadyPublished(bytes32 bytecodeHash);
// 0xac4a3f98
error FacetExists(bytes4 selector, address);
// 0x3fce21be
error FeeParamsChangeTooLarge(uint256 oldPrice, uint256 newPrice, uint256 maxAllowedPrice);
// 0xc91cf3b1
error GasPerPubdataMismatch();
// 0x5ca97564
error GenesisBatchCommitmentIncorrect();
// 0x6d4a7df8
error GenesisBatchCommitmentZero();
// 0x7940c83f
error GenesisBatchHashZero();
// 0xb4fc6835
error GenesisIndexStorageZero();
// 0x3a1a8589
error GenesisUpgradeZero();
// 0xd356e6ba
error HashedLogIsDefault();
// 0x0b08d5be
error HashMismatch(bytes32 expected, bytes32 actual);
// 0xf11438d9
error IMTAlreadyInitialized();
// 0x62f8ffe2
error IMTLeafValueMismatch(uint256 expectedValue, uint256 actualValue);
// 0x037dc2ed
error IMTLowLeafIndexOutOfBounds(uint256 lowLeafIndex, uint256 leafCount);
// 0xd87e0e66
error IMTLowLeafNextTooSmall(uint256 lowNextValue, uint256 newValue);
// 0x74470b8f
error IMTLowLeafValueTooLarge(uint256 lowValue, uint256 newValue);
// 0xae48798a
error IMTNotInitialized();
// 0x68051076
error IMTValueAlreadyExists(uint256 value);
// 0xbd1de53d
error IMTValueZero();
// 0xd7d93e1f
error IncorrectBatchBounds(
    uint256 processFromExpected,
    uint256 processToExpected,
    uint256 processFromProvided,
    uint256 processToProvided
);
// 0xc1b4bc7b
error IncorrectBatchChainId(uint256, uint256);
// 0xdd381a4c
error IncorrectBridgeHubAddress(address bridgehub);
// 0x07859b3b
error InsufficientChainBalance(uint256 chainId, bytes32 assetId, uint256 amount);
// 0x03eb8b54
error InsufficientFunds(uint256 required, uint256 actual);
// 0xd70c44f6
error InteropSenderChainIdMismatch(uint256 senderChainId, uint256 payloadSourceChainId);
// 0x9bf8b9aa
error InvalidBatchNumber(uint256 provided, uint256 expected);
// 0xd438e1fa
error InvalidBlockRange(uint64 batchNumber, uint64 from, uint64 to);
// 0xcbd9d2e0
error InvalidCaller(address);
// 0x7a47c9a2
error InvalidChainId();
// 0x92daded2
error InvalidDAForPermanentRollup();
// 0x4fbe5dba
error InvalidDelay();
// 0x3f98a77e
error InvalidL2DACommitmentScheme(L2DACommitmentScheme);
// 0xc1780bd6
error InvalidLogSender(address sender, uint256 logKey);
// 0xa1ec1876
error InvalidMessageRoot(bytes32 expectedMessageRoot, bytes32 providedMessageRoot);
// 0xd08a97e6
error InvalidMockProofLength();
// 0xde4c0b96
error InvalidNTVBurnData();
// 0xd8e9405c
error InvalidNumberOfBlobs(uint256 expected, uint256 numCommitments, uint256 numHashes);
// 0x99f6cc22
error InvalidPackedPrecommitmentLength(uint256 length);
// 0x09bde339
error InvalidProof();
// 0x48c5fa28
error InvalidProofLengthForFinalNode();
// 0x5428eae7
error InvalidProtocolVersion();
// 0x6f1cf752
error InvalidPubdataPricingMode();
// 0x12ba286f
error InvalidSelector(bytes4 func);
// 0xbe7193d4
error InvalidSystemLogsLength();
// 0x7b7a98f1
error InvalidThreshold(uint256 max, uint256 got);
// 0xd857fbc0
error InvalidTxCountInPriorityMode(uint256 l2TxCount, uint256 l1TxCount);
// 0x5f1aa154
error InvalidUpgradeTxn(UpgradeTxVerifyParam);
// 0xfb5c22e6
error L2TimestampTooBig();
// 0xe37d2c02
error LengthIsNotDivisibleBy32(uint256 length);
// 0x1b6825bb
error LogAlreadyProcessed(uint8);
// 0x43e266b0
error MalformedBytecode(BytecodeError);
// 0x88b43745
error MalformedL2UpgradePlan();
// 0xafbb7a4e
error MerkleIndexOrHeightMismatch();
// 0x9bb54c35
error MerkleIndexOutOfBounds();
// 0xc33e6128
error MerkleNothingToProve();
// 0x8e23ac1a
error MerklePathEmpty();
// 0x09aa9830
error MerklePathLengthMismatch(uint256 pathLength, uint256 expectedLength);
// 0x1c500385
error MerklePathOutOfBounds();
// 0x1b582fcf
error MerkleWrongIndex(uint256 index, uint256 maxNodeNumber);
// 0x485cfcaa
error MerkleWrongLength(uint256 newLeavesLength, uint256 leafNumber);
// 0x3312a450
error MigrationPaused();
// 0x4e98b356
error MigrationsNotPaused();
// 0x7e472272
error MissingBaseTokenAssetId();
// 0xfa44b527
error MissingSystemLogs(uint256 expected, uint256 actual);
// 0x1508fb47
error MockVerifierNotSupported();
// 0x4a094431
error MsgValueMismatch(uint256 expectedMsgValue, uint256 providedMsgValue);
// 0xb385a3da
error MsgValueTooLow(uint256 required, uint256 provided);
// 0xedd74330
error MustBeEraChain();
// 0x8b7e144a
error NewDeadlineExceedsMaxDeadline();
// 0x6eef58d1
error NewDeadlineNotGreaterThanCurrent();
// 0x79cc2d22
error NoCallsProvided();
// 0x88dfa474
error NoCommittedUpgradeCutForVersion(uint256 protocolVersion);
// 0xce63ce17
error NoCTMForAssetId(bytes32 assetId);
// 0xa6fef710
error NoFunctionsForDiamondCut();
// 0xcab098d8
error NoFundsTransferred();
// 0xc4dc2673
error NonCanonicalRepresentation();
// 0xc21b1ab7
error NonEmptyCalldata();
// 0x536ec84b
error NonEmptyMsgValue();
// 0x3731bfa2
error NonFullPubdataContentForPermanentRollup();
// 0xd018e08e
error NonIncreasingTimestamp();
// 0x0105f9c0
error NonSequentialBatch();
// 0x0ac76f01
error NonSequentialVersion();
// 0x0e0ff4d9
error NonZeroBlobToVerifyZKsyncOS(uint256 index, bytes32 blobLinearHash, bytes32 blobOpeningCommitment);
// 0x31967fc6
error NonZeroCarriedHash();
// 0xfa5cd00f
error NotAllowed(address addr);
// 0x64846fe4
error NotARestriction(address addr);
// 0xf306a770
error NotAssetRouter(address sender, address assetRouter);
// 0xb49df1f2
error NotAZKChain(address addr);
// 0x7fdf8632
error NotCompatibleWithPriorityMode();
// 0x5e67e793
error NotCurrentSettlementLayer();
// 0x2b1dc354
error NotDangerousContract(address);
// 0x230f9d11
error NotEnoughSigners(uint256 provided, uint256 expected);
// 0xdd7e3621
error NotInitializedReentrancyGuard();
// 0xecb34449
error NotL1(uint256 l1ChainId, uint256 blockChainId);
// 0xc5441a63
error NotL2ToL2(uint256 sourceChainId, uint256 destinationChainId);
// 0xdf17e316
error NotWhitelisted(address);
// 0x9d7bb13f
error OnlyNormalMode();
// 0xd702c443
error OnlyPriorityMode();
// 0x6c167909
error OnlySelfAllowed();
// 0x1a21feed
error OperationExists();
// 0xeda2fbb1
error OperationMustBePending();
// 0xe1c1ff37
error OperationMustBeReady();
// 0xb926450e
error OriginChainIdNotFound();
// 0x352cb44f
error PatchMustReuseRelease(address fromRelease, address newRelease);
// 0x97da9c1c
error PayloadTooShort();
// 0x688c63e5
error PrecommitmentMismatch(uint256 batchNumber, bytes32 expected, bytes32 found);
// 0x9b48e060
error PreviousOperationNotExecuted();
// 0x67c198fe
error PriorityModeActivationTooEarly(uint256 earliestActivationTimestamp, uint256 currentTimestamp);
// 0xdbfcbbef
error PriorityModeIsNotAllowed();
// 0x2b9d9c4c
error PriorityModeRequiresPermanentRollup();
// 0xd5a99014
error PriorityOperationsRollingHashMismatch();
// 0xbeda0935
error PriorityOpsRequestTimestampMissing(uint256 requestId);
// 0x1a4d284a
error PriorityTxPubdataExceedsMaxPubDataPerBatch();
// 0xa461f651
error ProtocolIdMismatch(uint256 expectedProtocolVersion, uint256 providedProtocolId);
// 0x64f94ec2
error ProtocolIdNotGreater();
// 0x929dc94b
error ProxyUpgradeRowMismatch(address proxy, address expectedOldImpl, address actualImpl);
// 0xd95d4d82
error PubdataContentLockedForPermanentRollup();
// 0x959f26fb
error PubdataGreaterThanLimit(uint256 limit, uint256 length);
// 0x63c36549
error QueueIsEmpty();
// 0x881fba9f
error RecoverToL1NotSupported();
// 0xab143c06
error Reentrancy();
// 0xfc83be31
error RegistryCodehashMismatch(address target, bytes32 expected, bytes32 actual);
// 0x3e28bae4
error RegistryDuplicateProxyRow(address proxy);
// 0x22345d26
error RegistryDuplicateSelector(bytes4 selector);
// 0xba5f0dd8
error RegistryEmptySelectors(address facet);
// 0xb130ce79
error RegistryHashChangeToZero();
// 0xd79000b2
error RegistryInventoryLengthMismatch(uint256 expected, uint256 actual);
// 0xb40929f4
error RegistryMemberHasNoFixedAddress(uint256 member);
// 0x30f6031b
error RegistryMissingBaseSystemHash();
// 0xa0c88a92
error RegistryPinTargetHasNoCode(address target);
// 0x0d122829
error RegistryReleaseCodehashAlreadySet(bytes32 current);
// 0x1f20dafa
error RegistryUnknownKey();
// 0x3ea1345a
error RegistryWrongVM(bool expected, bool actual);
// 0x667d17de
error RemoveFunctionFacetAddressNotZero(address facet);
// 0xa2d4b16c
error RemoveFunctionFacetAddressZero();
// 0xf6fd7071
error RemovingPermanentRestriction();
// 0x3580370c
error ReplaceFunctionFacetAddressZero();
// 0xf126e113
error RestrictionWasAlreadyPresent(address restriction);
// 0x52e22c98
error RestrictionWasNotPresent(address restriction);
// 0x9a67c1cb
error RevertedBatchNotAfterNewLastBatch();
// 0xfe0aa4f2
error RoleAccessDenied(address chainAddress, bytes32 role, address account);
// 0xec81deed
error SameReleaseTransitionHasPayload();
// 0xd3b6535b
error SelectorsMustAllHaveSameFreezability();
// 0x02181a13
error SettlementLayersMustSettleOnL1();
// 0x856d5b77
error SharedBridgeNotSet();
// 0xabdc734e
error SignatureNotValid(address signer);
// 0xa665a34d
error SignaturesLengthMismatch(uint256 expected, uint256 actual);
// 0x3b94fe24
error SignerNotAuthorized(address signer);
// 0xa7781cbb
error SignersNotSorted();
// 0xdf3a8fdd
error SlotOccupied();
// 0xcc0f168b
error SystemContractProxyInitialized();
// 0xae43b424
error SystemLogsSizeTooBig();
// 0x08753982
error TimeNotReached(uint256 expectedTimestamp, uint256 actualTimestamp);
// 0x7a4902ad
error TimerAlreadyStarted();
// 0xf511412f
error TimerNotStarted();
// 0x2d50c33b
error TimestampError();
// 0xb1e96bbd
error TokenMultiplierChangeTooFrequent(uint256 nextAllowedTimestamp);
// 0x1850b46b
error TokenNotLegacy();
// 0x06439c6b
error TokenNotSupported(address token);
// 0x23830e28
error TokensWithFeesNotSupported();
// 0x8e3ce3cb
error TooHighDeploymentNonce();
// 0x76da24b9
error TooManyFactoryDeps();
// 0xf0b4e88f
error TooMuchGas();
// 0x00c5a6a9
error TransactionNotAllowed();
// 0x1b7def5a
error TransitionDeadlineBeforeUpgrade(uint256 deadline, uint256 upgradeTimestamp);
// 0x8d905e8b
error TransitionNotCommitted(address named, address committed);
// 0x01a7d6aa
error TransitionReleaseMismatch(address expected, address actual);
// 0x4c991078
error TxHashMismatch();
// 0x2e311df8
error TxnBodyGasLimitNotEnoughGas();
// 0xfcb9b2e1
error UnallowedImplementation(bytes32 implementationHash);
// 0x8e4a23d6
error Unauthorized(address caller);
// 0xe52478c7
error UndefinedDiamondCutAction();
// 0x6aa39880
error UnexpectedSystemLog(uint256 logKey);
// 0x8124d8ff
error UnexpectedUpgradeSelector();
// 0xc352bb73
error UnknownVerifierType();
// 0xf3dd1b9c
error UnsupportedCommitBatchEncoding(uint8 version);
// 0x084a1449
error UnsupportedEncodingVersion();
// 0x14d2ed8a
error UnsupportedExecuteBatchEncoding(uint8 version);
// 0xf338f830
error UnsupportedProofBatchEncoding(uint8 version);
// 0x1906f346
error UnsupportedUpgradeType();
// 0xf093c2e5
error UpgradeBatchNumberIsNotZero();
// 0xd7f878f7
error UpgradeNotPermissionlessYet(uint256 deadline);
// 0x04d91f9d
error UpgradeTimestampNotReached(uint256 upgradeTimestamp, uint256 currentTimestamp);
// 0x47b3b145
error ValidateTxnNotEnoughGas();
// 0x626ade30
error ValueMismatch(uint256 expected, uint256 actual);
// 0xe1022469
error VerifiedBatchesExceedsCommittedBatches();
// 0x750b219c
error WithdrawFailed();
// 0xf20c5c2a
error WrappedBaseTokenAlreadyRegistered();
// 0xf1ff6cf6
error WrongCTMDeployerVariant();
// 0x15e8e429
error WrongMagicValue(uint256 expectedMagicValue, uint256 providedMagicValue);
// 0xd92e233d
error ZeroAddress();
// 0xc84885d4
error ZeroChainId();
// 0x16787758
error ZeroUpgradeTimestamp();
// 0x601b6882
error ZKChainLimitReached();
// 0xb2cabab5
error ZKsyncOSChainConfigUpdateWithUnverifiedBatches(uint256 batchesVerified, uint256 batchesCommitted);
// 0x1df14b10
error ZKsyncOSMaxTxGasLimitTooHigh();
// 0x7e34baaf
error ZKsyncOSMaxTxGasLimitTooLow();
// 0x646ac57e
error ZKsyncOSNotForceDeployForExistingContract(address);
// 0xb24b1ccb
error ZKsyncOSNotForceDeployToPrecompileAddress(address);
// 0x3d9d4821
error ZKsyncOSPrecommitsNotSupported();
// 0x8464be6c
// 0xe45872b6
// @dev An ecosystem row's live implementation matches neither its source nor its target —

enum SharedBridgeKey {
    PostUpgradeFirstBatch,
    LegacyBridgeFirstBatch,
    LegacyBridgeLastDepositBatch,
    LegacyBridgeLastDepositTxn
}

enum BytecodeError {
    Version,
    NumberOfWords,
    Length,
    WordsMustBeOdd
}

enum UpgradeTxVerifyParam {
    From,
    To,
    Paymaster,
    Value,
    MaxFeePerGas,
    MaxPriorityFeePerGas,
    Reserved0,
    Reserved1,
    Reserved2,
    Reserved3,
    Signature,
    PaymasterInput,
    ReservedDynamic
}

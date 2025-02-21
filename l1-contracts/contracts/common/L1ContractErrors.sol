// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x5ecf2d7a
error AccessToFallbackDenied(address target, address invoker);
// 0x3995f750
error AccessToFunctionDenied(address target, bytes4 selector, address invoker);
// 0x6c167909
error OnlySelfAllowed();
// 0x52e22c98
error RestrictionWasNotPresent(address restriction);
// 0xf126e113
error RestrictionWasAlreadyPresent(address restriction);
// 0x3331e9c0
error CallNotAllowed(bytes call);
// 0xf6fd7071
error RemovingPermanentRestriction();
// 0xfcb9b2e1
error UnallowedImplementation(bytes32 implementationHash);
// 0x0dfb42bf
error AddressAlreadySet(address addr);
// 0x86bb51b8
error AddressHasNoCode(address);
// 0x1f73225f
error AddressMismatch(address expected, address supplied);
// 0x5e85ae73
error AmountMustBeGreaterThanZero();
// 0xfde974f4
error AssetHandlerDoesNotExist(bytes32 assetId);
// 0x1294e9e1
error AssetIdMismatch(bytes32 expected, bytes32 supplied);
// 0xfe919e28
error AssetIdAlreadyRegistered();
// 0x0bfcef28
error AlreadyWhitelisted(address);
// 0x04a0b7e9
error AssetIdNotSupported(bytes32 assetId);
// 0x6ef9a972
error BaseTokenGasPriceDenominatorNotSet();
// 0x55ad3fd3
error BatchHashMismatch(bytes32 expected, bytes32 actual);
// 0x2078a6a0
error BatchNotExecuted(uint256 batchNumber);
// 0xbd4455ff
error BatchNumberMismatch(uint256 expectedBatchNumber, uint256 providedBatchNumber);
// 0x6cf12312
error BridgeHubAlreadyRegistered();
// 0xdb538614
error BridgeMintNotImplemented();
// 0xe85392f9
error CanOnlyProcessOneBatch();
// 0x00c6ead2
error CantExecuteUnprovenBatches();
// 0xe18cb383
error CantRevertExecutedBatch();
// 0x24591d89
error ChainIdAlreadyExists();
// 0x717a1656
error ChainIdCantBeCurrentChain();
// 0xa179f8c9
error ChainIdMismatch();
// 0x23f3c357
error ChainIdNotRegistered(uint256 chainId);
// 0x8f620a06
error ChainIdTooBig();
// 0xf7a01e4d
error DelegateCallFailed(bytes returnData);
// 0x0a8ed92c
error DenominatorIsZero();
// 0xb4f54111
error DeployFailed();
// 0x138ee1a3
error DeployingBridgedTokenForNativeToken();
// 0xc7c9660f
error DepositDoesNotExist();
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
// 0x95b66fe9
error EmptyDeposit();
// 0x627e0872
error ETHDepositNotSupported();
// 0xac4a3f98
error FacetExists(bytes4 selector, address);
// 0xc91cf3b1
error GasPerPubdataMismatch();
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
// 0x601b6882
error ZKChainLimitReached();
// 0xdd381a4c
error IncorrectBridgeHubAddress(address bridgehub);
// 0x826fb11e
error InsufficientChainBalance();
// 0xcbd9d2e0
error InvalidCaller(address);
// 0x4fbe5dba
error InvalidDelay();
// 0xc1780bd6
error InvalidLogSender(address sender, uint256 logKey);
// 0xd8e9405c
error InvalidNumberOfBlobs(uint256 expected, uint256 numCommitments, uint256 numHashes);
// 0x09bde339
error InvalidProof();
// 0x5428eae7
error InvalidProtocolVersion();
// 0x6f1cf752
error InvalidPubdataPricingMode();
// 0x12ba286f
error InvalidSelector(bytes4 func);
// 0x0214acb6
error InvalidUpgradeTxn(UpgradeTxVerifyParam);
// 0xfb5c22e6
error L2TimestampTooBig();
// 0x97e1359e
error L2WithdrawalMessageWrongLength(uint256 messageLen);
// 0xe37d2c02
error LengthIsNotDivisibleBy32(uint256 length);
// 0x1b6825bb
error LogAlreadyProcessed(uint8);
// 0xcea34703
error MalformedBytecode(BytecodeError);
// 0x9bb54c35
error MerkleIndexOutOfBounds();
// 0x8e23ac1a
error MerklePathEmpty();
// 0x1c500385
error MerklePathOutOfBounds();
// 0x3312a450
error MigrationPaused();
// 0xfa44b527
error MissingSystemLogs(uint256 expected, uint256 actual);
// 0x4a094431
error MsgValueMismatch(uint256 expectedMsgValue, uint256 providedMsgValue);
// 0xb385a3da
error MsgValueTooLow(uint256 required, uint256 provided);
// 0x79cc2d22
error NoCallsProvided();
// 0xa6fef710
error NoFunctionsForDiamondCut();
// 0xcab098d8
error NoFundsTransferred();
// 0xc21b1ab7
error NonEmptyCalldata();
// 0x536ec84b
error NonEmptyMsgValue();
// 0xd018e08e
error NonIncreasingTimestamp();
// 0x0105f9c0
error NonSequentialBatch();
// 0x0ac76f01
error NonSequentialVersion();
// 0xdd7e3621
error NotInitializedReentrancyGuard();
// 0xdf17e316
error NotWhitelisted(address);
// 0xf3ed9dfa
error OnlyEraSupported();
// 0x1a21feed
error OperationExists();
// 0xeda2fbb1
error OperationMustBePending();
// 0xe1c1ff37
error OperationMustBeReady();
// 0xb926450e
error OriginChainIdNotFound();
// 0x9b48e060
error PreviousOperationNotExecuted();
// 0xd5a99014
error PriorityOperationsRollingHashMismatch();
// 0x1a4d284a
error PriorityTxPubdataExceedsMaxPubDataPerBatch();
// 0xa461f651
error ProtocolIdMismatch(uint256 expectedProtocolVersion, uint256 providedProtocolId);
// 0x64f94ec2
error ProtocolIdNotGreater();
// 0x959f26fb
error PubdataGreaterThanLimit(uint256 limit, uint256 length);
// 0x63c36549
error QueueIsEmpty();
// 0xab143c06
error Reentrancy();
// 0x667d17de
error RemoveFunctionFacetAddressNotZero(address facet);
// 0xa2d4b16c
error RemoveFunctionFacetAddressZero();
// 0x3580370c
error ReplaceFunctionFacetAddressZero();
// 0x9a67c1cb
error RevertedBatchNotAfterNewLastBatch();
// 0xd3b6535b
error SelectorsMustAllHaveSameFreezability();
// 0xd7a6b5e6
error SharedBridgeValueNotSet(SharedBridgeKey);
// 0x856d5b77
error SharedBridgeNotSet();
// 0xdf3a8fdd
error SlotOccupied();
// 0xec273439
error CTMAlreadyRegistered();
// 0xc630ef3c
error CTMNotRegistered();
// 0xae43b424
error SystemLogsSizeTooBig();
// 0x08753982
error TimeNotReached(uint256 expectedTimestamp, uint256 actualTimestamp);
// 0x2d50c33b
error TimestampError();
// 0x06439c6b
error TokenNotSupported(address token);
// 0x23830e28
error TokensWithFeesNotSupported();
// 0x76da24b9
error TooManyFactoryDeps();
// 0xf0b4e88f
error TooMuchGas();
// 0x00c5a6a9
error TransactionNotAllowed();
// 0x4c991078
error TxHashMismatch();
// 0x2e311df8
error TxnBodyGasLimitNotEnoughGas();
// 0x8e4a23d6
error Unauthorized(address caller);
// 0xe52478c7
error UndefinedDiamondCutAction();
// 0x6aa39880
error UnexpectedSystemLog(uint256 logKey);
// 0xf093c2e5
error UpgradeBatchNumberIsNotZero();
// 0x084a1449
error UnsupportedEncodingVersion();
// 0x47b3b145
error ValidateTxnNotEnoughGas();
// 0x626ade30
error ValueMismatch(uint256 expected, uint256 actual);
// 0xe1022469
error VerifiedBatchesExceedsCommittedBatches();
// 0xae899454
error WithdrawalAlreadyFinalized();
// 0x750b219c
error WithdrawFailed();
// 0x15e8e429
error WrongMagicValue(uint256 expectedMagicValue, uint256 providedMagicValue);
// 0xd92e233d
error ZeroAddress();
// 0xc84885d4
error ZeroChainId();
// 0x99d8fec9
error EmptyData();
// 0xf3dd1b9c
error UnsupportedCommitBatchEncoding(uint8 version);
// 0xf338f830
error UnsupportedProofBatchEncoding(uint8 version);
// 0x14d2ed8a
error UnsupportedExecuteBatchEncoding(uint8 version);
// 0xd7d93e1f
error IncorrectBatchBounds(
    uint256 processFromExpected,
    uint256 processToExpected,
    uint256 processFromProvided,
    uint256 processToProvided
);
// 0x64107968
error AssetHandlerNotRegistered(bytes32 assetId);
// 0x64846fe4
error NotARestriction(address addr);
// 0xfa5cd00f
error NotAllowed(address addr);
// 0xccdd18d2
error BytecodeAlreadyPublished(bytes32 bytecodeHash);
// 0x25d8333c
error CallerNotTimerAdmin();
// 0x907f8e51
error DeadlineNotYetPassed();
// 0x6eef58d1
error NewDeadlineNotGreaterThanCurrent();
// 0x8b7e144a
error NewDeadlineExceedsMaxDeadline();
// 0x2a5989a0
error AlreadyPermanentRollup();
// 0x92daded2
error InvalidDAForPermanentRollup();
// 0x7a4902ad
error TimerAlreadyStarted();

// 0x09aa9830
error MerklePathLengthMismatch(uint256 pathLength, uint256 expectedLength);

// 0xc33e6128
error MerkleNothingToProve();

// 0xafbb7a4e
error MerkleIndexOrHeightMismatch();

// 0x1b582fcf
error MerkleWrongIndex(uint256 index, uint256 maxNodeNumber);

// 0x485cfcaa
error MerkleWrongLength(uint256 newLeavesLength, uint256 leafNumber);

// 0xce63ce17
error NoCTMForAssetId(bytes32 assetId);
// 0x02181a13
error SettlementLayersMustSettleOnL1();
// 0x1850b46b
error TokenNotLegacy();
// 0x1929b7de
error IncorrectTokenAddressFromNTV(bytes32 assetId, address tokenAddress);
// 0x48c5fa28
error InvalidProofLengthForFinalNode();
// 0xfade089a
error LegacyEncodingUsedForNonL1Token();
// 0xa51fa558
error TokenIsLegacy();
// 0x29963361
error LegacyBridgeUsesNonNativeToken();
// 0x11832de8
error AssetRouterAllowanceNotZero();
// 0xaa5f6180
error BurningNativeWETHNotSupported();
// 0xb20b58ce
error NoLegacySharedBridge();
// 0x8e3ce3cb
error TooHighDeploymentNonce();
// 0x78d2ed02
error ChainAlreadyLive();
// 0x4e98b356
error MigrationsNotPaused();
// 0xf20c5c2a
error WrappedBaseTokenAlreadyRegistered();

// 0xde4c0b96
error InvalidNTVBurnData();
// 0xbe7193d4
error InvalidSystemLogsLength();
// 0x8efef97a
error LegacyBridgeNotSet();
// 0x767eed08
error LegacyMethodForNonL1Token();
// 0xc352bb73
error UnknownVerifierType();
// 0x456f8f7a
error EmptyProofLength();

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

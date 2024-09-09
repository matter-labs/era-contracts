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
// 0x59e1b0d2
error ChainZeroAddress();
// 0xff4bbdf1
error NotAHyperchain(address chainAddress);
// 0xa3decdf3
error NotAnAdmin(address expected, address actual);
// 0xf6fd7071
error RemovingPermanentRestriction();
// 0xfcb9b2e1
error UnallowedImplementation(bytes32 implementationHash);
// 0x1ff9d522
error AddressAlreadyUsed(address addr);
// 0x0dfb42bf
error AddressAlreadySet(address addr);
// 0x86bb51b8
error AddressHasNoCode(address);
// 0x1f73225f
error AddressMismatch(address expected, address supplied);
// 0x1eee5481
error AddressTooLow(address);
// 0x5e85ae73
error AmountMustBeGreaterThanZero();
// 0xfde974f4
error AssetHandlerDoesNotExist(bytes32 assetId);
// 0x1294e9e1
error AssetIdMismatch(bytes32 expected, bytes32 supplied);
//
error AssetIdAlreadyRegistered();
// 0x0bfcef28
error AlreadyWhitelisted(address);
// 0x04a0b7e9
error AssetIdNotSupported(bytes32 assetId);
// 0x6afd6c20
error BadReturnData();
// 0x6ef9a972
error BaseTokenGasPriceDenominatorNotSet();
// 0x55ad3fd3
error BatchHashMismatch(bytes32 expected, bytes32 actual);
// 0x2078a6a0
error BatchNotExecuted(uint256 batchNumber);
// 0xbd4455ff
error BatchNumberMismatch(uint256 expectedBatchNumber, uint256 providedBatchNumber);
// 0xafd53e2f
error BlobHashCommitmentError(uint256 index, bool blobHashEmpty, bool blobCommitmentEmpty);
// 0x6cf12312
error BridgeHubAlreadyRegistered();
//
error BridgeMintNotImplemented();
// 0xcf102c5a
error CalldataLengthTooBig();
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
//
error ChainIdNotRegistered(uint256 chainId);
//
error ChainNotLegacy();
// 0x78d2ed02
error ChainAlreadyLive();
// 0x8f620a06
error ChainIdTooBig();
// 0xf7a01e4d
error DelegateCallFailed(bytes returnData);
// 0x0a8ed92c
error DenominatorIsZero();
//
error DeployFailed();
// 0xc7c9660f
error DepositDoesNotExist();
// 0xad2fa98e
error DepositExists();
// 0x79cacff1
error DepositFailed();
// 0x0e7ee319
error DiamondAlreadyFrozen();
// 0x682dabb4
error DiamondFreezeIncorrectState();
// 0xa7151b9a
error DiamondNotFrozen();
//
error EmptyAddress();
// 0x2d4d012f
error EmptyAssetId();
// 0xfc7ab1d3
error EmptyBlobVersionHash(uint256 index);
//
error EmptyBytes32();
// 0x95b66fe9
error EmptyDeposit();
//
error ETHDepositNotSupported();
//
error FailedToTransferTokens(address tokenContract, address to, uint256 amount);
// 0xac4a3f98
error FacetExists(bytes4 selector, address);
// 0x79e12cc3
error FacetIsFrozen(bytes4 func);
error FunctionNotSupported();
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
// 0xb615c2b1
error ZKChainLimitReached();
//
error InsufficientAllowance(uint256 providedAllowance, uint256 requiredAmount);
// 0xdd381a4c
error IncorrectBridgeHubAddress(address bridgehub);
// 0x826fb11e
error InsufficientChainBalance();
// 0x356680b7
error InsufficientFunds();
//
error InvalidCaller(address);
// 0x7a47c9a2
error InvalidChainId();
// 0x4fbe5dba
error InvalidDelay();
// 0x0af806e0
error InvalidHash();
//
error InvalidInput();
// 0xc1780bd6
error InvalidLogSender(address sender, uint256 logKey);
// 0xd8e9405c
error InvalidNumberOfBlobs(uint256 expected, uint256 numCommitments, uint256 numHashes);
// 0x09bde339
error InvalidProof();
// 0x5428eae7
error InvalidProtocolVersion();
// 0x53e6d04d
error InvalidPubdataCommitmentsSize();
// 0x5513177c
error InvalidPubdataHash(bytes32 expectedHash, bytes32 provided);
// 0x9094af7e
error InvalidPubdataLength();
// 0xc5d09071
error InvalidPubdataMode();
// 0x6f1cf752
error InvalidPubdataPricingMode();
// 0x12ba286f
error InvalidSelector(bytes4 func);
// 0x5cb29523
error InvalidTxType(uint256 txType);
// 0x5f1aa154
error InvalidUpgradeTxn(UpgradeTxVerifyParam);
// 0xaa7feadc
error InvalidValue();
// 0xa4f62e33
error L2BridgeNotDeployed(uint256 chainId);
// 0xff8811ff
error L2BridgeNotSet(uint256 chainId);
// 0xcb5e4247
error L2BytecodeHashMismatch(bytes32 expected, bytes32 provided);
// 0xfb5c22e6
error L2TimestampTooBig();
// 0xd2c011d6
error L2UpgradeNonceNotEqualToNewProtocolVersion(uint256 nonce, uint256 protocolVersion);
// 0x97e1359e
error L2WithdrawalMessageWrongLength(uint256 messageLen);
// 0x32eb8b2f
error LegacyMethodIsSupportedOnlyForEra();
// 0xe37d2c02
error LengthIsNotDivisibleBy32(uint256 length);
// 0x1b6825bb
error LogAlreadyProcessed(uint8);
// 0x43e266b0
error MalformedBytecode(BytecodeError);
// 0x59170bf0
error MalformedCalldata();
// 0x16509b9a
error MalformedMessage();
// 0x9bb54c35
error MerkleIndexOutOfBounds();
// 0x8e23ac1a
error MerklePathEmpty();
// 0x1c500385
error MerklePathOutOfBounds();
//
error MigrationPaused();
// 0xfa44b527
error MissingSystemLogs(uint256 expected, uint256 actual);
// 0x4a094431
error MsgValueMismatch(uint256 expectedMsgValue, uint256 providedMsgValue);
// 0xb385a3da
error MsgValueTooLow(uint256 required, uint256 provided);
// 0x72ea85ad
error NewProtocolMajorVersionNotZero();
// 0x79cc2d22
error NoCallsProvided();
// 0xa6fef710
error NoFunctionsForDiamondCut();
// 0xcab098d8
error NoFundsTransferred();
// 0x92290acc
error NonEmptyBlobVersionHash(uint256 index);
// 0xc21b1ab7
error NonEmptyCalldata();
// 0x536ec84b
error NonEmptyMsgValue();
// 0xd018e08e
error NonIncreasingTimestamp();
// 0x0105f9c0
error NonSequentialBatch();
//
error NonSequentialVersion();
// 0x4ef79e5a
error NonZeroAddress(address);
// 0xdd629f86
error NotEnoughGas();
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
// 0xd7f50a9d
error PatchCantSetUpgradeTxn();
// 0x962fd7d0
error PatchUpgradeCantSetBootloader();
// 0x559cc34e
error PatchUpgradeCantSetDefaultAccount();
// 0x8d5851de
error PointEvalCallFailed(bytes);
// 0x4daa985d
error PointEvalFailed(bytes);
// 0x9b48e060
error PreviousOperationNotExecuted();
// 0x5c598b60
error PreviousProtocolMajorVersionNotZero();
// 0xa0f47245
error PreviousUpgradeNotCleaned();
// 0x101ba748
error PreviousUpgradeNotFinalized(bytes32 txHash);
// 0xd5a99014
error PriorityOperationsRollingHashMismatch();
// 0x1a4d284a
error PriorityTxPubdataExceedsMaxPubDataPerBatch();
// 0xa461f651
error ProtocolIdMismatch(uint256 expectedProtocolVersion, uint256 providedProtocolId);
// 0x64f94ec2
error ProtocolIdNotGreater();
// 0xd328c12a
error ProtocolVersionMinorDeltaTooBig(uint256 limit, uint256 proposed);
// 0x88d7b498
error ProtocolVersionTooSmall();
// 0x53dee67b
error PubdataCommitmentsEmpty();
// 0x7734c31a
error PubdataCommitmentsTooBig();
// 0x959f26fb
error PubdataGreaterThanLimit(uint256 limit, uint256 length);
// 0x2a4a14df
error PubdataPerBatchIsLessThanTxn();
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
// 0xdab52f4b
error RevertedBatchBeforeNewBatch();
// 0x9a67c1cb
error RevertedBatchNotAfterNewLastBatch();
// 0xd3b6535b
error SelectorsMustAllHaveSameFreezability();
// 0x7774d2f9
error SharedBridgeValueNotSet(SharedBridgeKey);
// 0xc1d9246c
error SharedBridgeBalanceMismatch();
// 0x856d5b77
error SharedBridgeNotSet();
// 0xcac5fc40
error SharedBridgeValueAlreadySet(SharedBridgeKey);
// 0xdf3a8fdd
error SlotOccupied();
// 0xd0bc70cf
error CTMAlreadyRegistered();
// 0x09865e10
error CTMNotRegistered();
// 0xae43b424
error SystemLogsSizeTooBig();
// 0x08753982
error TimeNotReached(uint256 expectedTimestamp, uint256 actualTimestamp);
// 0x2d50c33b
error TimestampError();
// 0x4f4b634e
error TokenAlreadyRegistered(address token);
// 0xddef98d7
error TokenNotRegistered(address token);
// 0x06439c6b
error TokenNotSupported(address token);
// 0x23830e28
error TokensWithFeesNotSupported();
// 0xf640f0e5
error TooManyBlobs();
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
// 0x07218375
error UnexpectedNumberOfFactoryDeps();
// 0x6aa39880
error UnexpectedSystemLog(uint256 logKey);
//
error UnimplementedMessage(string);
// 0xf093c2e5
error UpgradeBatchNumberIsNotZero();
//
error UnsupportedEncodingVersion();
//
error UnsupportedPaymasterFlow();
// 0x47b3b145
error ValidateTxnNotEnoughGas();
// 0x626ade30
error ValueMismatch(uint256 expected, uint256 actual);
// 0xe1022469
error VerifiedBatchesExceedsCommittedBatches();
// 0x2dbdba00
error VerifyProofCommittedVerifiedMismatch();
// 0xae899454
error WithdrawalAlreadyFinalized();
// 0x27fcd9d1
error WithdrawalFailed();
// 0x750b219c
error WithdrawFailed();
// 0x15e8e429
error WrongMagicValue(uint256 expectedMagicValue, uint256 providedMagicValue);
// 0xd92e233d
error ZeroAddress();
// 0x669567ea
error ZeroBalance();
// 0xc84885d4
error ZeroChainId();
// 0x520aa59c
error PubdataIsEmpty();
// 0x99d8fec9
error EmptyData();
// 0xc99a8360
error UnsupportedCommitBatchEncoding(uint8 version);
// 0xe167e4a6
error UnsupportedProofBatchEncoding(uint8 version);
// 0xe8e3f6f4
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
// 0x10f30e75
error NotBridgehub(address addr);
// 0x2554babc
error InvalidAddress(address expected, address actual);
// 0xfa5cd00f
error NotAllowed(address addr);

error MerklePathLengthMismatch(uint256 pathLength, uint256 expectedLength);

error MerkleNothingToProve();

error MerkleIndexOrHeightMismatch();

error MerkleWrongIndex(uint256 index, uint256 maxNodeNumber);

error MerkleWrongLength(uint256 newLeavesLength, uint256 leafNumber);

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

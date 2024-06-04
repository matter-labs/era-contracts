// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

// 0x8e4a23d6
error Unauthorized(address caller);
// 0x95b66fe9
error EmptyDeposit();
// 0x626ade30
error ValueMismatch(uint256 expected, uint256 actual);
// 0xae899454
error WithdrawalAlreadyFinalized();
// 0xd92e233d
error ZeroAddress();
// 0xcac5fc40
error SharedBridgeValueAlreadySet(SharedBridgeKey);
// 0xcab098d8
error NoFundsTransferred();
// 0x669567ea
error ZeroBalance();
// 0x536ec84b
error NonEmptyMsgValue();
// 0xa4f62e33
error L2BridgeNotDeployed(uint256 chainId);
// 0x06439c6b
error TokenNotSupported(address token);
// 0xc92b7c8f
error WithdrawIncorrectAmount();
// 0xad2fa98e
error DepositExists();
// 0x1ff9d522
error AddressAlreadyUsed(address addr);
// 0x09bde339
error InvalidProof();
// 0x8c04ba2d
error DepositDNE();
// 0x356680b7
error InsufficientFunds();
// 0x79cacff1
error DepositFailed();
// 0xfc1a3c3a
error ShareadBridgeValueNotSet(SharedBridgeKey);
// 0x750b219c
error WithdrawFailed();
// 0x16509b9a
error MalformedMessage();
// 0x12ba286f
error InvalidSelector(bytes4 func);
// 0xd0bc70cf
error STMAlreadyRegistered();
// 0x09865e10
error STMNotRegistered();
// 0x4f4b634e
error TokenAlreadyRegistered(address token);
// 0xddef98d7
error TokenNotRegistered(address token);
// 0x7a47c9a2
error InvalidChainId();
// 0xe4ed5fcc
error WethBridgeNotSet();
// 0x6cf12312
error BridgeHubAlreadyRegistered();
// 0x1eee5481
error AddressTooLow(address);
// 0xdf3a8fdd
error SlotOccupied();
// 0x43e266b0
error MalformedBytecode(BytecodeError);
// 0x72afcbf4
error OperationShouldBeReady();
// 0xee454a75
error OperationShouldBePending();
// 0x1a21feed
error OperationExists();
// 0x4fbe5dba
error InvalidDelay();
// 0x9b48e060
error PreviousOperationNotExecuted();
// 0x0b08d5be
error HashMismatch(bytes32 expected, bytes32 actual);
// 0xb615c2b1
error HyperchainLimitReached();
// 0x71dcf049
error TimeNotReached();
// 0xf0b4e88f
error TooMuchGas();
// 0x59170bf0
error MalformedCalldata();
// 0x79e12cc3
error FacetIsFrozen(bytes4 func);
// 0x2a4a14df
error PubdataPerBatchIsLessThanTxn();
// 0x6f1cf752
error InvalidPubdataPricingMode();
// 0xaa7feadc
error InvalidValue();
// 0x78d2ed02
error ChainAlreadyLive();
// 0x5428eae7
error InvalidProtocolVersion();
// 0x682dabb4
error DiamondFreezeIncorrectState();
// 0xc5d09071
error InvalidPubdataMode();
// 0x0af806e0
error InvalidHash();
// 0x9094af7e
error InvalidPubdataLength();
// 0xd018e08e
error NonIncreasingTimestamp();
// 0x2d50c33b
error TimestampError();
// 0x1b6825bb
error LogAlreadyProcessed(uint8);
// 0xc1780bd6
error InvalidLogSender(address sender, uint256 logKey);
// 0x6aa39880
error UnexpectedSystemLog(uint256 logKey);
// 0xfa44b527
error MissingSystemLogs(uint256 expected, uint256 actual);
// 0xe85392f9
error CanOnlyProcessOneBatch();
// 0x55ad3fd3
error BatchHashMismatch(bytes32 expected, bytes32 actual);
// 0xf093c2e5
error UpgradeBatchNumberIsNotZero();
// 0x0105f9c0
error NonSequentialBatch();
// 0x00c6ead2
error CantExecuteUnprovenBatches();
// 0x213eb372
error SystemLogsSizeOverflow();
// 0xd8e9405c
error InvalidNumberOfBlobs(uint256 expected, uint256 numCommitments, uint256 numHashes);
// 0x2dbdba00
error VerifyProofCommittedVerifiedMismatch();
// 0xdab52f4b
error RevertedBatchBeforeNewBatch();
// 0xe18cb383
error CantRevertExecutedBatch();
// 0x4daa985d
error PointEvalFailed(bytes);
// 0xfc7ab1d3
error EmptyBlobVersionHash(uint256 index);
// 0x4c991078
error TxHashMismatch();
// 0x92290acc
error NonEmptyBlobVersionHash(uint256 index);
// 0xafd53e2f
error BlobHashCommitmentError(uint256 index, bool blobHashEmpty, bool blobCommitmentEmpty);
// 0xf3ed9dfa
error OnlyEraSupported();
// 0x2078a6a0
error BatchNotExecuted(uint256 batchNumber);
// 0xd356e6ba
error HashedLogIsDefault();
// 0x6ef9a972
error BaseTokenGasPriceDenominatorNotSet();
// 0x00c5a6a9
error TransactionNotAllowed();
// 0xc91cf3b1
error GasPerPubdataMismatch();
// 0x76da24b9
error TooManyFactoryDeps();
// 0xb385a3da
error MsgValueTooLow(uint256 required, uint256 provided);
// 0xa6fef710
error NoFunctionsForDiamondCut();
// 0xe52478c7
error UndefinedDiamondCutAction();
// 0x86bb51b8
error AddressHasNoCode(address);
// 0xac4a3f98
error FacetExists(bytes4 selector, address);
// 0x4ef79e5a
error NonZeroAddress(address);
// 0xd3b6535b
error SelectorsMustAllHaveSameFreezability();
// 0xc21b1ab7
error NonEmptyCalldata();
// 0x6afd6c20
error BadReturnData();
// 0x8e23ac1a
error MerklePathEmpty();
// 0x1c500385
error MerklePathOutOfBounds();
// 0x9bb54c35
error MerkleIndexOutOfBounds();
// 0x63c36549
error QueueIsEmpty();
// 0x5f1aa154
error InvalidUpgradeTxn(UpgradeTxVerifyParam);
// 0xdd629f86
error NotEnoughGas();
// 0x5cb29523
error InvalidTxType(uint256 txType);
// 0x4ee1b0ed
error NewProtocolVersionNotInUpgradeTxn();
// 0x07218375
error UnexpectedNumberOfFactoryDeps();
// 0x101ba748
error PreviousUpgradeNotFinalized(bytes32 txHash);
// 0xa0f47245
error PreviousUpgradeNotCleaned();

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

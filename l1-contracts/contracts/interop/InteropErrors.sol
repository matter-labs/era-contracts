// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x979e85dd
error AtomicBundleToL1NotSupported();
// 0x9031f751
error AttributeAlreadySet(bytes4 selector);
// 0xbcb41ec7
error AttributeViolatesRestriction(bytes4 selector, uint256 restriction);
// 0x5bba5111
error BundleAlreadyProcessed(bytes32 bundleHash);
// 0xd5c7a376
error CallAlreadyExecuted(bytes32 bundleHash, uint256 callIndex);
// 0xc087b727
error CallNotExecutable(bytes32 bundleHash, uint256 callIndex);
// 0xe9380b27
error CannotInitiateInteropOnL1();
// 0xf729f26d
error CanNotUnbundle(bytes32 bundleHash);
// 0x99be92a3
error ChainFeatureNotEnabled(bytes32 feature);
// 0x23b449be
error DestinationChainNotAllowed(uint256 destinationChainId);
// 0x2d159f39
error DestinationChainNotRegistered(uint256 destinationChainId);
// 0x43f0659c
error DirectCallToL1NotSupported();
// 0x558c44fc
error EmptyBundle();
// 0xe845be4c
error ExecutingNotAllowed(bytes32 bundleHash, bytes callerAddress, bytes executionAddress);
// 0x16b0fa00
error FeeWithdrawalFailed();
// 0x4afc3319
error IndirectCallCannotCarryValue(uint256 value);
// 0x8014ad84
error IndirectCallOnlyToAssetRouter(address target);
// 0x62d214aa
error IndirectCallValueMismatch(uint256 expected, uint256 actual);
// 0xbfa9bcca
error InteropBundleSaltAlreadyUsed(address user, bytes32 salt);
// 0xd9b009c7
error InteropCallToL1NotToAssetRouter(address target);
// 0x9c86555d
error InteropCounterpartsConflict(uint256 chainId);
// 0xddfef0ad
error InteropCounterpartsNotSet(uint256 chainId);
// 0x0aabb78d
error InteropCounterpartsNotSupported(uint256 chainId, uint256 protocolVersion);
// 0xfe8b1b16
error InteroperableAddressChainReferenceNotEmpty(bytes interoperableAddress);
// 0x884f49ba
error InteroperableAddressNotEmpty(bytes interoperableAddress);
// 0x290dc1c0
error InteropPreviewHash(bytes32 bundleHash);
// 0x2d48e8cf
error InteropRootAlreadyExists();
// 0x466ffc88
error InteropRootSourceAlreadyAssigned(uint256 sourceChainId, uint256 assignedToChainId);
// 0xda97a9c2
error InteropRootSourceInUse(uint256 sourceChainId, uint256 assignedToChainId);
// 0x722f0f07
error InteropRootSourceNotAssigned(uint256 chainId, uint256 sourceChainId);
// 0x8a011102
error InteropRootTimestampIsZero();
// 0x54936b89
error InteropRootWriterNotSet(uint256 chainId, uint256 sourceChainId);
// 0x3cebbbfd
error InteropRootWritersNotEnabled();
// 0x97c3045a
error InteropRootWritersNotSupported(uint256 chainId, uint256 protocolVersion);
// 0x9b021130
error InteropToSelfNotSupported();
// 0xeae192ef
error InvalidInteropBundleVersion();
// 0xd5f13973
error InvalidInteropCallVersion();
// 0x251310fd
error InvalidInteropCounterparts(address interopCenter, address assetRouter);
// 0xc8fed078
error InvalidInteropRootSource(uint256 sourceChainId);
// 0x32c2e156
error MessageNotIncluded();
// 0x6a430157
error MultiCallToL1NotSupported(uint256 callCount);
// 0x1db1b07e
error NonAtomicSendUnsupported();
// 0xd72e81d8
error NonZeroValueToL1NotSupported(uint256 value);
// 0x6f5d3620
error NotSettlingOnL1(uint256 settlementLayerChainId);
// 0x1c6cf858
error OneWayAssetOriginNotAllowed(uint256 chainId, bytes32 assetId, uint256 originChainId);
// 0x6f0fa85a
error OneWayBundleAttributeNotSupported(bytes4 selector);
// 0x7df64077
error OneWayBundleNotSingleCall(uint256 callCount);
// 0xd46f1fda
error OneWayCallNotIndirect();
// 0xd82724d8
error OneWayCallNotToAssetRouter(address target);
// 0x1074c1c0
error OneWayCallValueNotZero(uint256 value);
// 0x294a8348
error ProofNotSelfRooted(uint256 chainId, uint256 settlementLayerChainId);
// 0xb0321c67
error RecoveryToOneWayDestinationNotSupported(uint256 chainId);
// 0xce834c7b
error SettlementLayerIsWriterSource(uint256 settlementLayerChainId, uint256 chainId);
// 0x5af78ecd
error ShadowAccountNotSupported();
// 0x2f59bd0d
error SidesLengthNotOne();
// 0x89fd2c76
error UnauthorizedMessageSender(address expected, address actual);
// 0x0345c281
error UnbundlingNotAllowed(bytes32 bundleHash, bytes callerAddress, bytes unbundlerAddress);
// 0x1ef20f93
error WriterRootNotCurrent(uint256 chainId, uint256 blockNumber);
// 0x801534e9
error WrongCallStatusLength(uint256 bundleCallsLength, uint256 providedCallStatusLength);
// 0xb99d46dc
error WrongDestinationBaseTokenAssetId(bytes32 bundleHash, bytes32 expected, bytes32 actual);
// 0x4534e972
error WrongDestinationChainId(bytes32 bundleHash, uint256 expected, uint256 actual);
// 0x534ab1b2
error WrongSourceChainId(bytes32 bundleHash, uint256 expected, uint256 actual);
// 0x92196069
error ZKTokenNotAvailable();

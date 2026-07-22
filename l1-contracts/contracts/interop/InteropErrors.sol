// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x979e85dd
/// @notice An atomic bundle declares L1 as its destination.
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
// 0xa8ab28c8
/// @notice An interop bundle send was attempted on L1.
error CannotInitiateInteropOnL1(uint256 destinationChainId);
// 0xf729f26d
error CanNotUnbundle(bytes32 bundleHash);
// 0x2d159f39
error DestinationChainNotRegistered(uint256 destinationChainId);
// 0x43f0659c
/// @notice An L2->L1 bundle contains a direct (non-indirect) call.
error DirectCallToL1NotSupported();
// 0x558c44fc
/// @notice The supplied bundle bytes are empty.
error EmptyBundle();
// 0xe845be4c
error ExecutingNotAllowed(bytes32 bundleHash, bytes callerAddress, bytes executionAddress);
// 0x16b0fa00
error FeeWithdrawalFailed();
// 0x62d214aa
error IndirectCallValueMismatch(uint256 expected, uint256 actual);
// 0xbfa9bcca
/// @notice The sender already used this bundle salt.
error InteropBundleSaltAlreadyUsed(address user, bytes32 salt);
// 0xd9b009c7
/// @notice An L2->L1 call targets a contract other than the L2 asset router.
error InteropCallToL1NotToAssetRouter(address target);
// 0xfe8b1b16
error InteroperableAddressChainReferenceNotEmpty(bytes interoperableAddress);
// 0x884f49ba
error InteroperableAddressNotEmpty(bytes interoperableAddress);
// 0x290dc1c0
error InteropPreviewHash(bytes32 bundleHash);
// 0x9b021130
/// @notice The bundle's destination is the sending chain itself.
error InteropToSelfNotSupported();
// 0x2d48e8cf
error InteropRootAlreadyExists();
// 0x8a011102
/// @notice An interop root import carries a zero timestamp.
error InteropRootTimestampIsZero();
// 0xeae192ef
error InvalidInteropBundleVersion();
// 0xd5f13973
error InvalidInteropCallVersion();
// 0x32c2e156
error MessageNotIncluded();
// 0x6a430157
/// @notice An L2->L1 bundle contains more than one call.
error MultiCallToL1NotSupported(uint256 callCount);
// 0x1db1b07e
error NonAtomicSendUnsupported();
// 0xd72e81d8
/// @notice An L2->L1 call carries a non-zero interop call value.
error NonZeroValueToL1NotSupported(uint256 value);
// 0x2f59bd0d
error SidesLengthNotOne();
// 0x89fd2c76
error UnauthorizedMessageSender(address expected, address actual);
// 0x0345c281
error UnbundlingNotAllowed(bytes32 bundleHash, bytes callerAddress, bytes unbundlerAddress);
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

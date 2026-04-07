// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

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
// 0xf36a88e5
error CannotClaimInteropOnL1Settlement();
// 0xf729f26d
error CanNotUnbundle(bytes32 bundleHash);
// 0x2d159f39
error DestinationChainNotRegistered(uint256 destinationChainId);
// 0xe845be4c
error ExecutingNotAllowed(bytes32 bundleHash, bytes callerAddress, bytes executionAddress);
// 0x16b0fa00
error FeeWithdrawalFailed();
// 0x62d214aa
error IndirectCallValueMismatch(uint256 expected, uint256 actual);
// 0xfe8b1b16
error InteroperableAddressChainReferenceNotEmpty(bytes interoperableAddress);
// 0x884f49ba
error InteroperableAddressNotEmpty(bytes interoperableAddress);
// 0x2d48e8cf
error InteropRootAlreadyExists();
// 0xeae192ef
error InvalidInteropBundleVersion();
// 0xd5f13973
error InvalidInteropCallVersion();
// 0x32c2e156
error MessageNotIncluded();
// 0x73f59c74
error ShadowAccountAlreadyInitialized();
// 0xfbb13087
error ShadowAccountCallFailed(uint256 callIndex);
// 0x0bdba858
error ShadowAccountOnlyFactory();
// 0x57dd2d1c
error ShadowAccountOnlyInteropHandler();
// 0xc6febe57
error ShadowAccountOnlyOwner();
// 0x40f3e3b2
error ShadowAccountWithIndirectCall();
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

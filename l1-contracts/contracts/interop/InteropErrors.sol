// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

// 0x9031f751
error AttributeAlreadySet(bytes4 selector);
// 0xbcb41ec7
error AttributeViolatesRestriction(bytes4 selector, uint256 restriction);
// 0x5bba5111
error BundleAlreadyProcessed(bytes32 bundleHash);
// 0xa43d2953
error BundleVerifiedAlready(bytes32 bundleHash);
// 0xd5c7a376
error CallAlreadyExecuted(bytes32 bundleHash, uint256 callIndex);
// 0xc087b727
error CallNotExecutable(bytes32 bundleHash, uint256 callIndex);
// 0xf729f26d
error CanNotUnbundle(bytes32 bundleHash);
// 0xe845be4c
error ExecutingNotAllowed(bytes32 bundleHash, bytes callerAddress, bytes executionAddress);
// 0x62d214aa
error IndirectCallValueMismatch(uint256 expected, uint256 actual);
// 0x32c2e156
error MessageNotIncluded();
// 0x8ad61a4c
error SettlementLayerBatchNumberTooLow();
// 0x89fd2c76
error UnauthorizedMessageSender(address expected, address actual);
// 0x0345c281
error UnbundlingNotAllowed(bytes32 bundleHash, bytes callerAddress, bytes unbundlerAddress);
// 0xe1c9e479
error UnsupportedAttribute(bytes4 selector);
// 0x801534e9
error WrongCallStatusLength(uint256 bundleCallsLength, uint256 providedCallStatusLength);
// 0x4534e972
error WrongDestinationChainId(bytes32 bundleHash, uint256 expected, uint256 actual);
// 0x534ab1b2
error WrongSourceChainId(bytes32 bundleHash, uint256 expected, uint256 actual);

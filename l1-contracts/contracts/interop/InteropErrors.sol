// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;


// 0x04bb396e
error AttributeAlreadySet(uint256 index);
// 0xcd73770b
error AttributeNotForBundle(bytes4 selector);
// 0x2531ea93
error AttributeNotForCall(bytes4 selector);
// 0xec11242f
error AttributeNotForInteropCallValue(bytes4 selector);
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
// 0x44fe431f
error ExecutingNotAllowed(bytes32 bundleHash, address callerAddress, address executionAddress);
// 0x62d214aa
error IndirectCallValueMismatch(uint256 expected, uint256 actual);
// 0x32c2e156
error MessageNotIncluded();
// 0x924f9fb1
error UnbundlingNotAllowed(bytes32 bundleHash, address callerAddress, address unbundlerAddress);
// 0x801534e9
error WrongCallStatusLength(uint256 bundleCallsLength, uint256 providedCallStatusLength);

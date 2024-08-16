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
// 0x79cc2d22
error NoCallsProvided();
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
// 0xd92e233d
error ZeroAddress();

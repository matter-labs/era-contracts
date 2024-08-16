// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

error AccessToFallbackDenied(address target, address invoker);
error AccessToFunctionDenied(address target, bytes4 selector, address invoker);
error OnlySelfAllowed();
error RestrictionWasNotPresent(address restriction);
error RestrictionWasAlreadyPresent(address restriction);
error NoCallsProvided();
error CallNotAllowed(bytes call);
error ChainZeroAddress();
error NotAHyperchain(address chainAddress);
error NotAnAdmin(address expected, address actual);
error RemovingPermanentRestriction();
error UnallowedImplementation(bytes32 implementationHash);
error ZeroAddress();

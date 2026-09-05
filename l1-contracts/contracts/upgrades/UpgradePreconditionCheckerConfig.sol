// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

/// @dev Expected return value of `getSupportsUpgradePreconditionCheckerMagic`.
bytes32 constant UPGRADE_PRECONDITION_CHECKER_MAGIC = keccak256("UpgradePreconditionChecker");

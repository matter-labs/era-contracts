// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/// @title MockProxyUpgradeInitImpl
/// @notice Test-only implementation exercising the fixed `initializeUpgrade()` reinitializer
///         path: a row's `callInitializeUpgrade` boolean must trigger exactly one argument-less
///         call, atomically with the implementation swap. The stored counter is what the tests
///         assert; a real implementation's reinitialization values live in its own audited code
///         (constants/immutables, pinned by the row's codehash).
/// @dev No reinitializer replay guard: production implementations MUST carry one (the function
///      is external on the proxy); these tests assert the call count instead.
contract MockProxyUpgradeInitImpl {
    uint256 public initializeUpgradeCalls;

    function initializeUpgrade() external {
        ++initializeUpgradeCalls;
    }

    function version() external pure returns (uint256) {
        return 42;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @notice Lightweight dummy for L2AssetTracker used in L2BaseToken unit tests.
/// @dev Replaces broad vm.mockCall with real function dispatch so wrong selectors revert naturally.
/// Values must be immutable or constant so vm.etch copies them in bytecode.
/// State variables are NOT copied by vm.etch (only code, not storage).
contract DummyL2AssetTracker {
    uint256 public immutable L1_CHAIN_ID = 1;
    bool public immutable needBaseTokenTotalSupplyBackfill = false;

    function handleInitiateBaseTokenBridgingOnL2(uint256, uint256) external {}

    function handleFinalizeBaseTokenBridgingOnL2(uint256) external {}

    function backFillZKSyncOSBaseTokenV31MigrationData(uint256) external {}
}

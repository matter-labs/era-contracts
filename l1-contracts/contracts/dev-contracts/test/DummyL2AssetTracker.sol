// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts-v4/token/ERC20/IERC20.sol";

/// @notice Lightweight dummy for L2AssetTracker used in L2BaseToken unit tests.
/// @dev Replaces broad vm.mockCall with real function dispatch so wrong selectors revert naturally.
/// Values must be immutable or constant so vm.etch copies them in bytecode.
/// State variables are NOT copied by vm.etch (only code, not storage).
///
/// ## Recording mode
///
/// When constructed with a non-zero `_recordTarget`, the dummy enters recording mode.
/// On each `handleFinalizeBaseTokenBridgingOnL2` call it snapshots `totalSupply()` of the
/// target (for L2BaseTokenEra tests) or `balance` of the target (for BaseTokenHolder tests)
/// so the test can assert that the tracker was called BEFORE balances/totalSupply changed.
/// The constructor arg is immutable so the value survives `vm.etch`.
contract DummyL2AssetTracker {
    uint256 public immutable L1_CHAIN_ID = 1;

    /// @dev When non-zero, recording mode is active. The address to observe.
    address public immutable recordTarget;

    enum RecordMode {
        None,
        TotalSupply,
        Balance
    }
    RecordMode public immutable recordMode;

    /// @dev Storage slot 0 — snapshot taken during handleFinalizeBaseTokenBridgingOnL2.
    uint256 public recordedValue;
    /// @dev Storage slot 1 — set to true when handleFinalizeBaseTokenBridgingOnL2 is called.
    bool public wasCalled;

    /// @dev The outbound flow reported by the caller, so tests can assert what was forwarded, and a
    /// per-direction call count so they can assert that nothing was reported.
    uint256 public recordedToChainId;
    uint256 public recordedToAmount;
    uint256 public toChainCalls;
    uint256 public fromChainCalls;

    constructor(address _recordTarget, RecordMode _recordMode) {
        recordTarget = _recordTarget;
        recordMode = _recordMode;
    }

    function handleInitiateBaseTokenBridgingOnL2(uint256 _toChainId, uint256 _amount) external {
        recordedToChainId = _toChainId;
        recordedToAmount = _amount;
        toChainCalls++;
    }

    function assertBaseTokenRecoveryIsAccountingNeutral(uint256) external {}

    function handleFinalizeBaseTokenBridgingOnL2(uint256, uint256) external {
        fromChainCalls++;

        if (recordTarget != address(0)) {
            if (recordMode == RecordMode.TotalSupply) {
                recordedValue = IERC20(recordTarget).totalSupply();
            } else if (recordMode == RecordMode.Balance) {
                recordedValue = recordTarget.balance;
            }
            wasCalled = true;
        }
    }
}

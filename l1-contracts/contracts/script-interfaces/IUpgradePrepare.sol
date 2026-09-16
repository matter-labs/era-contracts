// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreUpgradeParams, CTMUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Standalone core ecosystem upgrade entry point.
///         Pairs with `ICTMUpgradePrepare`. The legacy single-shot ecosystem
///         orchestrator was removed; protocol-ops now drives Core + per-CTM
///         forge invocations directly via `upgrade-prepare-all`.
/// @dev Deliberately not named after a release: every script generation subclasses the same
///      `DefaultCoreUpgrade`/`DefaultCTMUpgrade` bases and inherits these entry points unchanged.
interface ICoreUpgradePrepare {
    function noGovernancePrepare(CoreUpgradeParams memory _params) external;
}

/// @notice Standalone CTM upgrade entry point. Invoked once per CTM proxy when the
///         ecosystem hosts multiple CTMs (e.g. ZKsyncOS + EraVM).
interface ICTMUpgradePrepare {
    function noGovernancePrepare(CTMUpgradeParams memory _params) external;
}

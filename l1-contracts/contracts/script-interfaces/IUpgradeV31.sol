// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreUpgradeParams, CTMUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Standalone core ecosystem upgrade entry point.
///         Pairs with `ICTMUpgradeV31`. The legacy single-shot ecosystem
///         orchestrator was removed; protocol-ops now drives Core + per-CTM
///         forge invocations directly via `upgrade-prepare-all`.
interface ICoreUpgradeV31 {
    function noGovernancePrepare(CoreUpgradeParams memory _params) external;
}

/// @notice Standalone CTM upgrade entry point. Invoked once per CTM proxy when the
///         ecosystem hosts multiple CTMs (e.g. ZKsyncOS + EraVM).
interface ICTMUpgradeV31 {
    function noGovernancePrepare(CTMUpgradeParams memory _params) external;
}

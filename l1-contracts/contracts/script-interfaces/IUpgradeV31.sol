// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    ComposeOperationParams,
    CoreUpgradeParams,
    CTMUpgradeParams
} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

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

/// @notice The compose step of a registry-driven upgrade, run after the core and every CTM
///         prepare: deploys the `EcosystemUpgradeOperation` over their outputs and emits the
///         coordinator's `stage0/1/2(operation)` calls.
interface IComposeUpgradeOperation {
    function compose(ComposeOperationParams memory _params) external;
}

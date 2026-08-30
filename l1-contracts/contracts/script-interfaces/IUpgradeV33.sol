// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreUpgradeParams, CTMUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Standalone core ecosystem upgrade entry point for the v33 release.
///         Pairs with `ICTMUpgradeV33`; protocol-ops drives Core + per-CTM forge
///         invocations directly via `upgrade-prepare-all`.
/// @dev Unlike `ICoreUpgradeV31` there is no `stage3`: the bridged-token
///      registration and `bridgedOut` population it exposed were one-time
///      v30 -> v31 migration work and have no v33 counterpart.
interface ICoreUpgradeV33 {
    function noGovernancePrepare(CoreUpgradeParams memory _params) external;
}

/// @notice Standalone CTM upgrade entry point, invoked once per CTM proxy.
/// @dev v33 is a ZKsync OS-only release, so in practice this runs for the
///      ZKsyncOS CTM alone; `CTMUpgrade_v33` rejects Era CTMs outright.
interface ICTMUpgradeV33 {
    function noGovernancePrepare(CTMUpgradeParams memory _params) external;
}

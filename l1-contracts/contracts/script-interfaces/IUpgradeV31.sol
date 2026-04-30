// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    EcosystemUpgradeParams,
    CoreUpgradeParams,
    CTMUpgradeParams
} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IUpgradeV31 {
    function noGovernancePrepare(EcosystemUpgradeParams memory _params) external;
}

/// @notice Standalone core ecosystem upgrade entry point.
///         Pairs with `ICTMUpgradeV31` so the protocol-ops orchestrator can split the
///         monolithic ecosystem upgrade into separate Core + per-CTM forge invocations.
interface ICoreUpgradeV31 {
    function noGovernancePrepare(CoreUpgradeParams memory _params) external;
}

/// @notice Standalone CTM upgrade entry point. Invoked once per CTM proxy when the
///         ecosystem hosts multiple CTMs (e.g. ZKsyncOS + EraVM).
interface ICTMUpgradeV31 {
    function noGovernancePrepare(CTMUpgradeParams memory _params) external;
}

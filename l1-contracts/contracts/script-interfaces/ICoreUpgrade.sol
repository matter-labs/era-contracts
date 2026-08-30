// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CoreUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Core ecosystem upgrade entry point, implemented by {DefaultCoreUpgrade} and therefore by
///         every release's core upgrade script. protocol-ops encodes against this to drive
///         `ecosystem upgrade-prepare-all`, so a release only needs its own interface if it adds an
///         entry point the default does not have.
interface ICoreUpgrade {
    function noGovernancePrepare(CoreUpgradeParams memory _params) external;
}

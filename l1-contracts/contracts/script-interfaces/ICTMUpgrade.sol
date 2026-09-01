// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMUpgradeParams} from "deploy-scripts/upgrade/default-upgrade/UpgradeParams.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice CTM upgrade entry point, invoked once per CTM proxy. Implemented by {DefaultCTMUpgrade}
///         and therefore by every release's CTM upgrade script.
interface ICTMUpgrade {
    function noGovernancePrepare(CTMUpgradeParams memory _params) external;
}

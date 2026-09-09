// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ICoreUpgrade} from "./ICoreUpgrade.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Core upgrade entry points for the v33 release: the shared {ICoreUpgrade} plus the
///         post-governance step only this release needs.
interface ICoreUpgradeV33 is ICoreUpgrade {
    /// @notice Post-governance `bridgedOut` population; see `CoreUpgrade_v33.stage3`.
    function stage3(address _bridgehubProxy) external;
}

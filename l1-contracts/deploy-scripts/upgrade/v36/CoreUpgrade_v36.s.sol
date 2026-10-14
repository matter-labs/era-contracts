// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v36 upgrade — the first REGISTRY-DRIVEN edge after the
///         v35 bootstrap, and deliberately a small one: `L1MessageRoot` is the one ecosystem
///         implementation it changes. The base pipeline deploys it (when its code differs from the
///         live one) and pins it in a `CoreTransition`; the operation the CTM prepare deploys names
///         that registry and the coordinator's `execute` applies it through the `CoreUpgradeExecutor`.
///         This prepare emits no governance call of its own.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v36 is DefaultCoreUpgrade {
    /// @inheritdoc DefaultCoreUpgrade
    function changedEcosystemImplementations() internal view virtual override returns (string[] memory names) {
        names = new string[](1);
        names[0] = "L1MessageRoot";
    }
}

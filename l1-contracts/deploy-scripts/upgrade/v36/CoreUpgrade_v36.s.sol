// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v36 upgrade — the first REGISTRY-DRIVEN edge after the
///         v35 bootstrap, and deliberately a small one: `L1MessageRoot` is the one ecosystem
///         implementation it changes. The base pipeline deploys it (when its code differs from the
///         live one) and pins it in a Core-domain `ProxyUpgradeTransition`, which the merged bundle
///         applies through `CoreUpgradeExecutor.applyL1Upgrade`. This prepare emits no governance
///         call of its own; it deploys the successor `CoreUpgradeExecutor`, and the merge derives
///         the handover to it.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v36 is DefaultCoreUpgrade {
    /// @inheritdoc DefaultCoreUpgrade
    function changedEcosystemImplementations() internal view virtual override returns (string[] memory names) {
        names = new string[](1);
        names[0] = "L1MessageRoot";
    }

    /// @inheritdoc DefaultCoreUpgrade
    /// @dev v36 changes `CoreUpgradeExecutor`: it applies a `ProxyUpgradeTransition` by delegatecalling the
    ///      engine the transition pins (EVM-1657), which the v35 executor cannot. An ecosystem still
    ///      on the v35 executor gets a successor; one already on this build keeps its own.
    function replacesCoreUpgradeExecutor() internal view virtual override returns (bool) {
        return true;
    }
}

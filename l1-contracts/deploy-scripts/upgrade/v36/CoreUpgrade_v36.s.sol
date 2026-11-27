// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v36 upgrade — a REGISTRY-DRIVEN edge from v35. It changes the
///         `L1MessageRoot` and `ChainRegistrationSender` implementations, and gives the L1 wiring setters
///         of the Bridgehub, the CTMDeploymentTracker, the ChainAssetHandler, the Nullifier and the
///         AssetRouter to the upgrade authority as well as the owner. It also changes the `L1InteropHandler`,
///         `L1ChainAssetHandler` and `L1AssetRouter` code (security hardening). The base pipeline deploys them and
///         pins them in a Core-domain `ProxyUpgradeTransition`, which the merged bundle applies through
///         `CoreUpgradeExecutor.applyL1Upgrade`. This prepare emits no governance call of its own.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v36 is DefaultCoreUpgrade {
    /// @inheritdoc DefaultCoreUpgrade
    function changedEcosystemImplementations() internal view virtual override returns (string[] memory names) {
        names = new string[](8);
        names[0] = "L1MessageRoot";
        names[1] = "ChainRegistrationSender";
        names[2] = "L1Bridgehub";
        names[3] = "CTMDeploymentTracker";
        names[4] = "L1ChainAssetHandler";
        names[5] = "L1Nullifier";
        names[6] = "L1AssetRouter";
        names[7] = "L1InteropHandler";
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v36 upgrade — a REGISTRY-DRIVEN edge from v35. It changes
///         `L1MessageRoot`, and gives the L1 wiring setters of the Bridgehub, the CTMDeploymentTracker,
///         the ChainAssetHandler, the Nullifier and the AssetRouter to the upgrade authority as well
///         as the owner. The base pipeline deploys them and pins them in a Core-domain
///         `ProxyUpgradeTransition`, which the merged bundle applies through
///         `CoreUpgradeExecutor.applyL1Upgrade`. This prepare emits no governance call of its own.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v36 is DefaultCoreUpgrade {
    /// @inheritdoc DefaultCoreUpgrade
    function changedEcosystemImplementations() internal view virtual override returns (string[] memory names) {
        names = new string[](6);
        names[0] = "L1MessageRoot";
        names[1] = "L1Bridgehub";
        names[2] = "CTMDeploymentTracker";
        names[3] = "L1ChainAssetHandler";
        names[4] = "L1Nullifier";
        names[5] = "L1AssetRouter";
    }
}

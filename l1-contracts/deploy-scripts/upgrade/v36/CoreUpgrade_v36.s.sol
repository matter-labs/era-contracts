// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v36 upgrade — the first REGISTRY-DRIVEN edge after the
///         v35 bootstrap. The base pipeline deploys the changed ecosystem implementations (when
///         their code differs from the live one) and pins them in a Core-domain
///         `ProxyUpgradeTransition`, which the merged bundle applies through
///         `CoreUpgradeExecutor.applyL1Upgrade`. This prepare emits no governance call of its own.
/// @dev `L1MessageRoot` and `L1ChainAssetHandler` change code; the others differ from v35 in their metadata only,
///      because shared sources they import changed.
// solhint-disable-next-line contract-name-capwords
contract CoreUpgrade_v36 is DefaultCoreUpgrade {
    /// @inheritdoc DefaultCoreUpgrade
    function changedEcosystemImplementations() internal view virtual override returns (string[] memory names) {
        names = new string[](9);
        names[0] = "L1Bridgehub";
        names[1] = "L1MessageRoot";
        names[2] = "L1ChainAssetHandler";
        names[3] = "L1Nullifier";
        names[4] = "L1AssetRouter";
        names[5] = "L1NativeTokenVault";
        names[6] = "CTMDeploymentTracker";
        names[7] = "L1InteropHandler";
        names[8] = "ChainRegistrationSender";
    }
}

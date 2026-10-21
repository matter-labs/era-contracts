// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

// solhint-disable gas-custom-errors

import {ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";
import {L1EcosystemContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {DefaultCoreUpgrade} from "../default-upgrade/DefaultCoreUpgrade.s.sol";

/// @notice Core (ecosystem) side of the v36 upgrade — the first REGISTRY-DRIVEN edge after the
///         v35 bootstrap. The base pipeline deploys the changed ecosystem implementations (when
///         their code differs from the live one) and pins them in a Core-domain
///         `ProxyUpgradeTransition`, which the merged bundle applies through
///         `CoreUpgradeExecutor.applyL1Upgrade`. This prepare emits no governance call of its own.
/// @dev L1SLOAD ({protocol-docs/l1sload.md#upgrade-from-v35}) changes the executable code of `L1MessageRoot` (the
///      anchor record), `ChainRegistrationSender` (suspension, the base token snapshot and its backfill) and
///      `L1AssetRouter` (its shared base). Against the v35 build at `2d08bda` the other six differ in their CBOR
///      metadata alone, because shared sources in their import closure (`Config.sol`, the error and interface files)
///      changed. Recheck the list against the v35 release build before preparing.
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

    /// @inheritdoc DefaultCoreUpgrade
    /// @dev The `ChainRegistrationSender` swap runs its `initializeUpgrade`, the base token backfill of the pairs
    ///      allowed under v35 ({protocol-docs/l1sload.md#upgrade-from-v35}). A run that reuses the live
    ///      implementation has no row to reinitialize.
    function _coreProxyUpgradeRows() internal view virtual override returns (ProxyUpgradeRow[] memory rows) {
        rows = super._coreProxyUpgradeRows();
        uint256 chainRegistrationSenderRow = uint256(L1EcosystemContract.ChainRegistrationSender);
        if (rows[chainRegistrationSenderRow].proxy != address(0)) {
            rows[chainRegistrationSenderRow].callInitializeUpgrade = true;
        }
    }
}

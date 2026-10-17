// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ManifestStorage} from "./ManifestStorage.sol";
import {IProxyUpgradeTransition} from "./IProxyUpgradeTransition.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {RegistryUnknownKey} from "../../../common/L1ContractErrors.sol";
import {ProxyUpgradeDomain, ProxyUpgradeRow, ProxyUpgradeTransitionManifest} from "../RegistryTypes.sol";

/// @title Proxy upgrade transition — one instance per domain per protocol upgrade.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Write-once object pinning one domain's proxy implementation swaps (see `CTMRelease` for
///         the model): the manifest is written at construction and there is no state-mutating
///         function, so a per-instance review is a pure DATA check (read the getters or compare
///         {manifestHash} against the audited manifest).
/// @dev Rows are source-checked edges (`expectedOldImpl -> implNew`). What each `implNew` RUNS is
///      what governance reviewed before approving this object; the object's own job is to refuse a
///      target that is not a deployed contract at all.
contract ProxyUpgradeTransition is IProxyUpgradeTransition, ManifestStorage {
    /// @notice Pins the full manifest.
    /// @param _manifest The manifest to pin. Its inventory length is checked against the member
    ///        count of `_manifest.domain`'s contract enum — never a caller-supplied length.
    constructor(ProxyUpgradeTransitionManifest memory _manifest) ManifestStorage(abi.encode(_manifest)) {
        ProxyUpgradeRow[] memory participating = ProxyUpgradeRowLib.toRows(
            _manifest.proxyUpgrades,
            ProxyUpgradeRowLib.inventoryLength(_manifest.domain)
        );
        // A transition that upgrades nothing is not a transition, it is a mistake: an upgrade that
        // leaves a domain alone omits that domain's call instead.
        if (participating.length == 0) {
            revert RegistryUnknownKey();
        }
        ProxyUpgradeRowLib.validateRows(participating);
    }

    /// @inheritdoc IProxyUpgradeTransition
    function getManifest() public view returns (ProxyUpgradeTransitionManifest memory) {
        return abi.decode(encodedManifest, (ProxyUpgradeTransitionManifest));
    }

    /// @inheritdoc IProxyUpgradeTransition
    function domain() external view returns (ProxyUpgradeDomain) {
        return getManifest().domain;
    }

    /// @inheritdoc IProxyUpgradeTransition
    function rows() external view returns (ProxyUpgradeRow[] memory) {
        return _rows();
    }

    /// @inheritdoc IProxyUpgradeTransition
    function validate() external view {
        ProxyUpgradeRowLib.requireRowCode(_rows());
    }

    function _rows() private view returns (ProxyUpgradeRow[] memory) {
        ProxyUpgradeTransitionManifest memory m = getManifest();
        return ProxyUpgradeRowLib.toRows(m.proxyUpgrades, ProxyUpgradeRowLib.inventoryLength(m.domain));
    }
}

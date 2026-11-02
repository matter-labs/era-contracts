// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IProxyUpgradeEngine} from "../engines/IProxyUpgradeEngine.sol";
import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {ProxyUpgradeDomainMismatch, UpgradeEngineChangedExecutorOwnership} from "../../../common/L1ContractErrors.sol";
import {ObjectAnchorLib} from "../libraries/ObjectAnchorLib.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {
    ProxyUpgradeContext,
    ProxyUpgradeDomain,
    ProxyUpgradeRow,
    ProxyUpgradeTransitionManifest
} from "../RegistryTypes.sol";

/// @title ProxyUpgradeExecutorBase
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice What both domain executors share to apply a `ProxyUpgradeTransition`: the ONE
///         delegatecall they make, into the engine the transition pins, with the fixed
///         `IProxyUpgradeEngine.executeUpgrade` selector and arguments the executor builds itself.
/// @dev The engine runs with the executor's authority and storage. What the executor still holds
///      after it returns: its own ownership (owner and pending owner unchanged) and every row's
///      proxy at its `implNew`. Anything else the engine does is what governance reviewed when it
///      approved the transition, and the engine's own postconditions.
abstract contract ProxyUpgradeExecutorBase is UpgradeExecutorBase {
    /// @param _initialOwner The governance executor that drives the fixed domain entrypoints.
    constructor(address _initialOwner) UpgradeExecutorBase(_initialOwner) {}

    /// @notice Applies `_transition` through its pinned engine.
    /// @param _proxyAdmin The executor's bound `ProxyAdmin`.
    /// @param _transition The write-once transition governance approved.
    /// @param _domain The executor's domain; the transition must be of it.
    /// @param _chainTypeManager The executor's bound CTM, or zero in the `Core` domain.
    function _applyProxyUpgradeTransition(
        ProxyAdmin _proxyAdmin,
        IProxyUpgradeTransition _transition,
        ProxyUpgradeDomain _domain,
        address _chainTypeManager
    ) internal {
        ObjectAnchorLib.requireCode(address(_transition));
        ProxyUpgradeTransitionManifest memory manifest = _transition.getManifest();
        if (manifest.domain != _domain) {
            revert ProxyUpgradeDomainMismatch(uint8(_domain), uint8(manifest.domain));
        }
        // A codeless delegatecall target succeeds silently.
        ObjectAnchorLib.requireCode(manifest.upgradeEngine);

        ProxyUpgradeContext memory context = ProxyUpgradeContext({
            transition: address(_transition),
            upgradeEngine: manifest.upgradeEngine,
            domain: _domain,
            proxyAdmin: address(_proxyAdmin),
            chainTypeManager: _chainTypeManager
        });
        address ownerBefore = owner();
        address pendingOwnerBefore = pendingOwner();
        // slither-disable-next-line controlled-delegatecall
        (bool success, bytes memory returnData) = manifest.upgradeEngine.delegatecall(
            abi.encodeCall(IProxyUpgradeEngine.executeUpgrade, (context, manifest.proxyUpgrades))
        );
        if (!success) {
            // Bubbled verbatim, empty data included: a leg reverts exactly as its rows did when the
            // executor applied them itself.
            assembly {
                revert(add(returnData, 0x20), mload(returnData))
            }
        }
        // The engine shares the executor's storage; it must not have touched who governs it.
        if (owner() != ownerBefore || pendingOwner() != pendingOwnerBefore) {
            revert UpgradeEngineChangedExecutorOwnership(manifest.upgradeEngine);
        }
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(
            manifest.proxyUpgrades,
            ProxyUpgradeRowLib.inventoryLength(_domain)
        );
        ProxyUpgradeRowLib.requireRowsApplied(_proxyAdmin, rows);
    }
}

// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {IProxyUpgradeEngine} from "../engines/IProxyUpgradeEngine.sol";
import {IProxyUpgradeTransition} from "../objects/IProxyUpgradeTransition.sol";
import {UpgradeExecutorBase} from "../../../governance/UpgradeExecutorBase.sol";
import {IOwnable} from "../../../common/interfaces/IOwnable.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {
    ProxyUpgradeDomainMismatch,
    ProxyUpgradeEngineChangedExecutorOwnership,
    ProxyUpgradeEngineMovedDomainAuthority
} from "../../../common/L1ContractErrors.sol";
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
/// @dev The engine runs with the executor's authority and storage. What the executor checks after
///      it returns: its own ownership (owner and pending owner unchanged), the holders of the domain
///      it lends the engine (the `ProxyAdmin`'s owner and, in a CTM domain, the CTM's owner, pending
///      owner, admin, proxy admin and ServerNotifier, and that ServerNotifier's owner, pending owner
///      and proxy admin, unchanged; a succession or a re-pointed ServerNotifier is a `forward`, not a
///      leg) and every row's proxy at its `implNew`.
///      Anything else the engine does is what governance reviewed when it approved the transition,
///      and the engine's own postconditions.
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
        ObjectAnchorLib.requireCode(manifest.proxyUpgradeEngine);

        ProxyUpgradeContext memory context = ProxyUpgradeContext({
            transition: address(_transition),
            proxyUpgradeEngine: manifest.proxyUpgradeEngine,
            domain: _domain,
            proxyAdmin: address(_proxyAdmin),
            chainTypeManager: _chainTypeManager
        });
        address ownerBefore = owner();
        address pendingOwnerBefore = pendingOwner();
        bytes32 domainHoldersBefore = _domainHolders(_proxyAdmin, _chainTypeManager);
        // slither-disable-next-line controlled-delegatecall
        (bool success, bytes memory returnData) = manifest.proxyUpgradeEngine.delegatecall(
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
            revert ProxyUpgradeEngineChangedExecutorOwnership(manifest.proxyUpgradeEngine);
        }
        if (_domainHolders(_proxyAdmin, _chainTypeManager) != domainHoldersBefore) {
            revert ProxyUpgradeEngineMovedDomainAuthority(manifest.proxyUpgradeEngine);
        }
        // A CTM the `ProxyAdmin` no longer administers answers `getProxyAdmin` with its own `admin()`:
        // were that the `ProxyAdmin`, a moved CTM would hash as unmoved.
        if (_chainTypeManager != address(0) && IChainTypeManager(_chainTypeManager).admin() == address(_proxyAdmin)) {
            revert ProxyUpgradeEngineMovedDomainAuthority(manifest.proxyUpgradeEngine);
        }
        ProxyUpgradeRow[] memory rows = ProxyUpgradeRowLib.toRows(
            manifest.proxyUpgrades,
            ProxyUpgradeRowLib.inventoryLength(_domain)
        );
        ProxyUpgradeRowLib.requireRowsApplied(_proxyAdmin, rows);
    }

    /// @notice Who holds the domain the executor lends the engine, hashed for comparison.
    /// @param _proxyAdmin The executor's bound `ProxyAdmin`.
    /// @param _chainTypeManager The executor's bound CTM, or zero in the `Core` domain.
    /// @return The hash of the `ProxyAdmin`'s owner and, with a CTM, the CTM's owner, pending owner,
    ///         admin, proxy admin and ServerNotifier, and that ServerNotifier's owner, pending owner and
    ///         proxy admin.
    /// @dev A proxy `_proxyAdmin` no longer administers passes `getProxyAdmin`'s `admin()` query to its
    ///      implementation: a moved CTM answers its own `admin()` (the caller refuses that being the
    ///      `ProxyAdmin`), a moved ServerNotifier has none and reverts the leg. The CTM's
    ///      `pendingAdmin` is private, so a nomination is not compared.
    function _domainHolders(ProxyAdmin _proxyAdmin, address _chainTypeManager) private view returns (bytes32) {
        if (_chainTypeManager == address(0)) {
            return keccak256(abi.encode(_proxyAdmin.owner()));
        }
        IOwnable ctm = IOwnable(_chainTypeManager);
        address serverNotifier = IChainTypeManager(_chainTypeManager).serverNotifierAddress();
        bytes32 holders = keccak256(
            abi.encode(
                _proxyAdmin.owner(),
                ctm.owner(),
                ctm.pendingOwner(),
                IChainTypeManager(_chainTypeManager).admin(),
                _proxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(_chainTypeManager)),
                serverNotifier
            )
        );
        if (serverNotifier == address(0)) {
            return holders;
        }
        IOwnable notifier = IOwnable(serverNotifier);
        return
            keccak256(
                abi.encode(
                    holders,
                    notifier.owner(),
                    notifier.pendingOwner(),
                    _proxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(serverNotifier))
                )
            );
    }
}

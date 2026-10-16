// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ObjectAnchorLib} from "./ObjectAnchorLib.sol";
import {CTMUpgradeExecutor} from "../executors/CTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "../executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "../executors/EcosystemUpgradeExecutor.sol";
import {IChainTypeManager} from "../../../state-transition/IChainTypeManager.sol";
import {ServerNotifier} from "../../../governance/ServerNotifier.sol";
import {
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    BootstrapExecutorOwnerMismatch,
    BootstrapNominationPending,
    BootstrapServerNotifierNotBound
} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The authority shape of a registry-era ecosystem — what a completed bootstrap leaves behind
///         and what a fresh deployment is born with: the coordinator and both domain executors owned
///         by one governance and bound to each other, and every authority of both domains held by its
///         executor. See "Authority" in {docs/registry-driven-upgrades.md}.
library RegistryAuthorityLib {
    /// @notice Every address the authority shape names.
    /// @param ctm The ChainTypeManager proxy.
    /// @param ctmProxyAdmin The CTM-domain `ProxyAdmin`.
    /// @param serverNotifier The CTM's ServerNotifier proxy.
    /// @param ctmExecutor The `CTMUpgradeExecutor` bound to `ctm`.
    /// @param coreExecutor The `CoreUpgradeExecutor` bound to the ecosystem `ProxyAdmin`.
    /// @param coordinator The `EcosystemUpgradeExecutor` both domain executors answer to.
    /// @param governance The owner of all three executors.
    // solhint-disable-next-line gas-struct-packing
    struct Authority {
        address ctm;
        ProxyAdmin ctmProxyAdmin;
        address serverNotifier;
        address ctmExecutor;
        address coreExecutor;
        address coordinator;
        address governance;
    }

    /// @notice Reverts unless the whole shape holds: the CTM and its `ProxyAdmin` are the CTM
    ///         executor's with no nomination outstanding on the CTM, the executors are governed and
    ///         bound ({requireExecutorsBound}), and the ServerNotifier is the CTM domain's
    ///         ({requireNotifierHandedOver}).
    /// @param _a The authority shape to check.
    function requireRegistryAuthority(Authority memory _a) internal view {
        address ctmOwner = Ownable2Step(_a.ctm).owner();
        if (ctmOwner != _a.ctmExecutor) {
            revert BootstrapAuthorityNotHeld(_a.ctm, ctmOwner);
        }
        requireNoNomination(_a.ctm);
        address proxyAdminOwner = _a.ctmProxyAdmin.owner();
        if (proxyAdminOwner != _a.ctmExecutor) {
            revert BootstrapAuthorityNotHeld(address(_a.ctmProxyAdmin), proxyAdminOwner);
        }
        requireExecutorsBound(_a);
        requireNotifierHandedOver(_a);
    }

    /// @notice Reverts unless every executor is checked BY VALUE against what it is handed: each is
    ///         owned by `governance` with no nomination outstanding (an executor whose ownership
    ///         moved would act for its new owner; a nominee could claim it), the CTM executor is
    ///         bound to the CTM and its `ProxyAdmin`, both domain executors answer to the coordinator
    ///         and the coordinator names both, and the ecosystem `ProxyAdmin` is the core executor's.
    /// @param _a The authority shape to check.
    function requireExecutorsBound(Authority memory _a) internal view {
        ObjectAnchorLib.requireCode(_a.ctmExecutor);
        ObjectAnchorLib.requireCode(_a.coreExecutor);
        ObjectAnchorLib.requireCode(_a.coordinator);
        _requireGovernedBy(_a.ctmExecutor, _a.governance);
        _requireGovernedBy(_a.coreExecutor, _a.governance);
        _requireGovernedBy(_a.coordinator, _a.governance);

        CTMUpgradeExecutor ctmExecutor = CTMUpgradeExecutor(payable(_a.ctmExecutor));
        _requireBound(_a.ctmExecutor, _a.coordinator, ctmExecutor.coordinator());
        _requireBound(_a.ctmExecutor, _a.ctm, address(ctmExecutor.CHAIN_TYPE_MANAGER()));
        _requireBound(_a.ctmExecutor, address(_a.ctmProxyAdmin), address(ctmExecutor.CTM_PROXY_ADMIN()));

        CoreUpgradeExecutor coreExecutor = CoreUpgradeExecutor(payable(_a.coreExecutor));
        _requireBound(_a.coreExecutor, _a.coordinator, coreExecutor.coordinator());

        EcosystemUpgradeExecutor coordinator = EcosystemUpgradeExecutor(payable(_a.coordinator));
        _requireBound(_a.coordinator, _a.coreExecutor, address(coordinator.CORE_EXECUTOR()));
        _requireBound(_a.coordinator, _a.ctmExecutor, address(coordinator.ctmExecutor()));

        address ecosystemProxyAdmin = address(coreExecutor.PROXY_ADMIN());
        address ecosystemProxyAdminOwner = coreExecutor.PROXY_ADMIN().owner();
        if (ecosystemProxyAdminOwner != _a.coreExecutor) {
            revert BootstrapAuthorityNotHeld(ecosystemProxyAdmin, ecosystemProxyAdminOwner);
        }
    }

    /// @notice Reverts unless the ServerNotifier is the CTM's and serves it, sits under the CTM-domain
    ///         `ProxyAdmin`, and is owned by the CTM executor with no nomination outstanding.
    /// @dev `getProxyAdmin` reverts without data while the proxy is still under another admin: a
    ///      transparent proxy answers `admin()` only to its own admin.
    /// @param _a The authority shape to check.
    function requireNotifierHandedOver(Authority memory _a) internal view {
        address ctmNotifier = IChainTypeManager(_a.ctm).serverNotifierAddress();
        if (ctmNotifier != _a.serverNotifier) {
            revert BootstrapServerNotifierNotBound(_a.serverNotifier, ctmNotifier);
        }
        address notifierCtm = address(ServerNotifier(_a.serverNotifier).chainTypeManager());
        if (notifierCtm != _a.ctm) {
            revert BootstrapServerNotifierNotBound(_a.ctm, notifierCtm);
        }
        address notifierOwner = Ownable2Step(_a.serverNotifier).owner();
        if (notifierOwner != _a.ctmExecutor) {
            revert BootstrapAuthorityNotHeld(_a.serverNotifier, notifierOwner);
        }
        requireNoNomination(_a.serverNotifier);
        address notifierAdmin = _a.ctmProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(_a.serverNotifier));
        if (notifierAdmin != address(_a.ctmProxyAdmin)) {
            revert BootstrapAuthorityNotHeld(_a.serverNotifier, notifierAdmin);
        }
    }

    /// @notice Reverts while an `Ownable2Step` nomination is outstanding on `_target`.
    /// @param _target An `Ownable2Step` authority of the shape.
    function requireNoNomination(address _target) internal view {
        address pendingOwner = Ownable2Step(_target).pendingOwner();
        if (pendingOwner != address(0)) {
            revert BootstrapNominationPending(_target, pendingOwner);
        }
    }

    /// @param _executor An executor of the shape.
    /// @param _governance The owner it must answer to.
    function _requireGovernedBy(address _executor, address _governance) private view {
        address owner = Ownable2Step(_executor).owner();
        if (owner != _governance) {
            revert BootstrapExecutorOwnerMismatch(_executor, _governance, owner);
        }
        requireNoNomination(_executor);
    }

    /// @param _executor The executor (or coordinator) whose binding is read.
    /// @param _expected What it must be bound to.
    /// @param _actual What it is bound to.
    function _requireBound(address _executor, address _expected, address _actual) private pure {
        if (_actual != _expected) {
            revert BootstrapExecutorNotBound(_executor, _expected, _actual);
        }
    }
}

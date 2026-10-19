// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {StdAssertions} from "forge-std/StdAssertions.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {BootstrapManifest, ProxyUpgradeRow} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @notice The post-state of a registry edge, asserted by the tests and the fork replay themselves:
///         the contracts check only what can change between review and execution, and a completed
///         edge's state is a post-condition of reviewed code within one transaction — see
///         {protocol-docs/ecosystem-upgrade.md#where-each-check-lives}. protocol-ops asserts the
///         same after a replay (`registry::applied`), and so do the anvil runners.
abstract contract RegistryPostState is StdAssertions {
    /// @notice The bootstrap edge completed: the CTM at the genesis release's version on that
    ///         release, every CTM-domain row at its `implNew`, and the whole CTM domain — the
    ///         ServerNotifier included — held by the bound CTM executor, which answers to the
    ///         manifest's governance like the core executor, with no nomination outstanding.
    function _assertBootstrapApplied(RegistryBootstrapMigration _migration) internal view {
        BootstrapManifest memory m = _migration.getManifest();
        IChainTypeManager ctm = IChainTypeManager(m.ctm);
        assertTrue(_migration.executed(), "the migration ran");
        assertEq(ctm.protocolVersion(), _migration.newProtocolVersion(), "the CTM is at the edge's version");
        assertEq(ctm.currentRelease(), m.currentRelease, "the CTM runs the edge's release");
        assertEq(
            ICTMRelease(m.currentRelease).protocolVersion(),
            ctm.protocolVersion(),
            "the installed release is the release of the CTM's version"
        );

        for (uint256 i = 0; i < m.ctmProxyUpgrades.length; ++i) {
            ProxyUpgradeRow memory row = m.ctmProxyUpgrades[i];
            if (row.implNew != address(0)) {
                assertEq(
                    m.ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(row.proxy)),
                    row.implNew,
                    "every CTM-domain row runs its implNew"
                );
            }
        }

        _assertCTMHeldBy(ctm, m.ctmExecutor);
        _assertNotifierHeldBy(ctm, m.ctmExecutor);
        CTMUpgradeExecutor ctmExecutor = CTMUpgradeExecutor(payable(m.ctmExecutor));
        assertEq(address(ctmExecutor.CHAIN_TYPE_MANAGER()), m.ctm, "the CTM executor is bound to the CTM");
        assertEq(address(ctmExecutor.CTM_PROXY_ADMIN()), address(m.ctmProxyAdmin), "and to its ProxyAdmin");
        address notifier = m.ctmProxyUpgrades[uint256(CTMContract.ServerNotifier)].proxy;
        assertEq(ctm.serverNotifierAddress(), notifier, "the CTM names the manifest's notifier");
        assertEq(
            m.ctmProxyAdmin.getProxyAdmin(ITransparentUpgradeableProxy(notifier)),
            address(m.ctmProxyAdmin),
            "the notifier sits under the CTM-domain ProxyAdmin"
        );

        _assertGovernedBy(m.ctmExecutor, m.governance);
        _assertGovernedBy(m.coreExecutor, m.governance);
        assertEq(
            Ownable2Step(address(CoreUpgradeExecutor(payable(m.coreExecutor)).PROXY_ADMIN())).owner(),
            m.coreExecutor,
            "the ecosystem ProxyAdmin is the core executor's"
        );
    }

    /// @notice `_transition` is committed on `_ctm` and the CTM moved to its target: the edge it
    ///         departs from names it, the CTM is at its new version on its new release, and the CTM
    ///         is still held by `_ctmExecutor`.
    function _assertTransitionApplied(
        IChainTypeManager _ctm,
        ICTMTransition _transition,
        address _ctmExecutor
    ) internal view {
        assertEq(
            _ctm.upgradeTransition(_transition.oldProtocolVersion()),
            address(_transition),
            "the departure commits the transition"
        );
        assertEq(_ctm.protocolVersion(), _transition.newProtocolVersion(), "the CTM is at the transition's target");
        assertEq(_ctm.currentRelease(), _transition.newRelease(), "the CTM runs the transition's release");
        assertEq(
            ICTMRelease(_ctm.currentRelease()).protocolVersion(),
            _ctm.protocolVersion(),
            "the installed release is the release of the CTM's version"
        );
        _assertCTMHeldBy(_ctm, _ctmExecutor);
    }

    /// @notice The CTM and its ProxyAdmin are `_ctmExecutor`'s with no CTM nomination outstanding.
    function _assertCTMHeldBy(IChainTypeManager _ctm, address _ctmExecutor) internal view {
        assertEq(Ownable2Step(address(_ctm)).owner(), _ctmExecutor, "the CTM executor owns the CTM");
        assertEq(Ownable2Step(address(_ctm)).pendingOwner(), address(0), "no CTM nomination is outstanding");
        CTMUpgradeExecutor ctmExecutor = CTMUpgradeExecutor(payable(_ctmExecutor));
        assertEq(
            Ownable2Step(address(ctmExecutor.CTM_PROXY_ADMIN())).owner(),
            _ctmExecutor,
            "the CTM executor owns the CTM-domain ProxyAdmin"
        );
    }

    /// @notice The CTM's ServerNotifier is `_ctmExecutor`'s with no nomination outstanding, and
    ///         serves the CTM.
    function _assertNotifierHeldBy(IChainTypeManager _ctm, address _ctmExecutor) internal view {
        address notifier = _ctm.serverNotifierAddress();
        assertEq(Ownable2Step(notifier).owner(), _ctmExecutor, "the CTM executor owns the notifier");
        assertEq(Ownable2Step(notifier).pendingOwner(), address(0), "no notifier nomination is outstanding");
        assertEq(address(ServerNotifier(notifier).chainTypeManager()), address(_ctm), "the notifier serves the CTM");
    }

    function _assertGovernedBy(address _executor, address _governance) internal view {
        assertEq(Ownable2Step(_executor).owner(), _governance, "the executor answers to governance");
        assertEq(Ownable2Step(_executor).pendingOwner(), address(0), "no executor nomination is outstanding");
    }
}

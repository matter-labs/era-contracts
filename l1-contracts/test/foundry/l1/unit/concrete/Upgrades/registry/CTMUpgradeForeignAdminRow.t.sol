// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {CTMContract} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {ProxyUpgradeRowMismatch} from "contracts/common/L1ContractErrors.sol";
import {ProxyUpgradeRow, TransitionManifest} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @dev Three distinct implementations so a proxy row is a real `expectedOldImpl -> implNew`
///      edge and a proxy can also sit at an implementation the row does not know.
contract NotifierImplOld {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract NotifierImplNew {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract NotifierImplOther {
    function version() external pure returns (uint256) {
        return 3;
    }
}

/// @notice CTM-domain rows under a FOREIGN `ProxyAdmin` — the ServerNotifier shape of
///         {docs/upgrade-stage-lifecycle.md} section 4.4 and "A row names its admin" in
///         {docs/registry-driven-upgrades.md}: a per-CTM proxy administered by an admin the CTM
///         executor may or may not own. Stage 1 applies such a row only when the executor OWNS
///         its admin and otherwise leaves it to that administrator (logged, not reverted); stage 2
///         requires it applied either way, read through the row's own admin.
/// @dev Every transition here carries one row under the executor's bound admin (the
///      `ValidatorTimelock` slot) next to the foreign row (the `ServerNotifier` slot), so the two
///      apply policies are observed side by side within one stage. Rows apply in inventory order,
///      so the bound-admin row's event always precedes the foreign row's.
contract CTMUpgradeForeignAdminRowTest is CTMUpgradeExecutorFixture {
    address internal implOld;
    address internal implNew;
    address internal implOther;
    address internal chainAdmin;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    ProxyAdmin internal notifierAdmin;
    TransparentUpgradeableProxy internal notifierProxy;

    function setUp() public override {
        super.setUp();
        implOld = address(new NotifierImplOld());
        implNew = address(new NotifierImplNew());
        implOther = address(new NotifierImplOther());
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        // The notifier's own admin, owned by the chain admin rather than by the CTM executor.
        chainAdmin = makeAddr("chainAdmin");
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(chainAdmin);
        notifierProxy = new TransparentUpgradeableProxy(implOld, address(notifierAdmin), hex"");
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _row(
        address _proxy,
        address _expectedOldImpl,
        address _implNew,
        ProxyAdmin _admin
    ) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: _pin(_implNew),
                callInitializeUpgrade: false,
                admin: _admin
            });
    }

    /// @dev The fixture's default manifest plus the bound-admin row and the foreign-admin row.
    function _deployTransitionWithForeignRow() internal returns (CTMTransition) {
        TransitionManifest memory manifest = _transitionManifest(
            777,
            chainContractAddress.currentRelease(),
            0,
            L2_DELEGATE_CODE
        );
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(
            address(ctmDomainProxy),
            implOld,
            implNew,
            ProxyAdmin(address(0))
        );
        manifest.proxyUpgrades[uint256(CTMContract.ServerNotifier)] = _row(
            address(notifierProxy),
            implOld,
            implNew,
            notifierAdmin
        );
        return new CTMTransition(manifest);
    }

    function _liveImpl(ProxyAdmin _admin, TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return _admin.getProxyImplementation(ITransparentUpgradeableProxy(address(_proxy)));
    }

    /// @dev The administrator's own upgrade call — the `ctm_admin_calls` leg in production.
    function _chainAdminMovesNotifier(address _impl) internal {
        vm.prank(chainAdmin);
        notifierAdmin.upgrade(ITransparentUpgradeableProxy(address(notifierProxy)), _impl);
    }

    /// @dev The other operating mode: the notifier's admin is handed to the CTM executor.
    function _handNotifierAdminToExecutor() internal {
        vm.prank(chainAdmin);
        notifierAdmin.transferOwnership(address(ctmExecutor));
    }

    function _countLogs(
        Vm.Log[] memory _logs,
        address _emitter,
        bytes32 _topic0
    ) internal pure returns (uint256 count) {
        for (uint256 i = 0; i < _logs.length; ++i) {
            if (_logs[i].emitter == _emitter && _logs[i].topics[0] == _topic0) {
                ++count;
            }
        }
    }

    function _assertPendingWithHold(CTMTransition _transition, ICTMUpgradeExecutor.UpgradeStage _stage) internal view {
        assertEq(address(ctmExecutor.pendingTransition()), address(_transition), "the lifecycle must stay open");
        _assertStage(_stage);
        assertTrue(chainAssetHandler.upgradePauseHeld(address(ctmExecutor)), "the executor's hold must stay");
        assertTrue(chainAssetHandler.migrationPaused(), "migrations must stay paused");
    }

    function _assertLifecycleIdle() internal view {
        assertEq(address(ctmExecutor.pendingTransition()), address(0), "the lifecycle slot must be cleared");
        _assertStage(ICTMUpgradeExecutor.UpgradeStage.None);
        assertFalse(chainAssetHandler.upgradePauseHeld(address(ctmExecutor)), "the hold must be released");
        assertFalse(chainAssetHandler.migrationPaused(), "the executor's hold was the only pause");
    }

    // ─────────────────────────── left to the administrator ───────────────────────────

    /// @dev The default operating mode: the executor does not own the notifier's admin. Stage 1
    ///      applies the bound-admin row, leaves the foreign row (logged) and otherwise completes;
    ///      stage 2 requires the foreign row applied and holds the lifecycle open — pause and all —
    ///      until the administrator's own upgrade lands.
    function test_stage1_leavesUnownedForeignRowToItsAdministrator_stage2WaitsForIt() public {
        CTMTransition t = _deployTransitionWithForeignRow();
        _stage0(t);

        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ctmDomainProxy), implNew);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyRowLeftToAdministrator(address(notifierProxy), address(notifierAdmin));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.UpgradeExecuted(address(t));
        _stage1(t);

        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the bound-admin row must be applied");
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implOld, "the foreign row must be left as it was");
        assertEq(notifierAdmin.owner(), chainAdmin, "the foreign admin stays with its owner");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the CTM leg must otherwise complete");
        assertEq(chainContractAddress.upgradeTransition(0), address(t));
        _assertPendingWithHold(t, ICTMUpgradeExecutor.UpgradeStage.Executed);

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(notifierProxy), implNew, implOld)
        );
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(t)));
        _assertPendingWithHold(t, ICTMUpgradeExecutor.UpgradeStage.Executed);

        _chainAdminMovesNotifier(implNew);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.UpgradeCompleted(address(t));
        _stage2(t);

        _assertLifecycleIdle();
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implNew);
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(t)));
    }

    /// @dev The production ordering: the administrator's call lands BEFORE the bundle, so stage 1
    ///      finds the foreign row already at `implNew`. Not owned, the row is still left to its
    ///      administrator (logged) — there is nothing to do — and stage 2 passes at once.
    function test_stage1_unownedForeignRowAlreadyApplied_stage2PassesAtOnce() public {
        _chainAdminMovesNotifier(implNew);
        CTMTransition t = _deployTransitionWithForeignRow();
        _stage0(t);

        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyRowLeftToAdministrator(address(notifierProxy), address(notifierAdmin));
        _stage1(t);
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implNew, "the row stays where the administrator put it");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew);

        _stage2(t);
        _assertLifecycleIdle();
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(t)));
    }

    /// @dev Not owned, the row is not source-checked by stage 1 — it is the administrator's. An
    ///      administrator that moved the proxy somewhere the row does not know is caught by stage 2,
    ///      which reads the row through ITS admin, and the lifecycle waits for the correction.
    function test_stage2_catchesUnownedForeignRowAtUnexpectedImplementation() public {
        _chainAdminMovesNotifier(implOther);
        CTMTransition t = _deployTransitionWithForeignRow();
        _stage0(t);

        _stage1(t);
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implOther, "stage 1 leaves the foreign row alone");
        assertEq(chainContractAddress.protocolVersion(), newVersion);

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(notifierProxy), implNew, implOther)
        );
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(t)));
        _assertPendingWithHold(t, ICTMUpgradeExecutor.UpgradeStage.Executed);

        _chainAdminMovesNotifier(implNew);
        _stage2(t);
        _assertLifecycleIdle();
    }

    // ─────────────────────────── owned by the executor ───────────────────────────

    /// @dev The other operating mode: the notifier's admin was handed to the CTM executor, so the
    ///      foreign row rides stage 1 exactly like a bound-admin row and stage 2 has nothing to
    ///      wait for.
    function test_stage1_appliesForeignRowWhenTheExecutorOwnsItsAdmin() public {
        _handNotifierAdminToExecutor();
        assertEq(notifierAdmin.owner(), address(ctmExecutor));
        CTMTransition t = _deployTransitionWithForeignRow();
        _stage0(t);

        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ctmDomainProxy), implNew);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(notifierProxy), implNew);
        vm.recordLogs();
        _stage1(t);

        assertEq(
            _countLogs(
                vm.getRecordedLogs(),
                address(ctmExecutor),
                ProxyUpgradeRowLib.ProxyRowLeftToAdministrator.selector
            ),
            0,
            "an owned row is applied, never left"
        );
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implNew, "the foreign row rides stage 1");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew);

        _stage2(t);
        _assertLifecycleIdle();
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(t)));
    }

    /// @dev Owned and already at `implNew`: the same idempotence as a bound-admin row — skipped
    ///      silently, no event of either kind for it.
    function test_stage1_skipsOwnedForeignRowAlreadyAtImplNew() public {
        _chainAdminMovesNotifier(implNew);
        _handNotifierAdminToExecutor();
        CTMTransition t = _deployTransitionWithForeignRow();
        _stage0(t);

        vm.recordLogs();
        _stage1(t);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        assertEq(
            _countLogs(logs, address(ctmExecutor), ProxyUpgradeRowLib.ProxyRowLeftToAdministrator.selector),
            0,
            "an owned row is never left to an administrator"
        );
        assertEq(
            _countLogs(logs, address(ctmExecutor), ProxyUpgradeRowLib.ProxyImplementationUpgraded.selector),
            1,
            "only the bound-admin row had anything to do"
        );
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implNew);

        _stage2(t);
        _assertLifecycleIdle();
    }

    /// @dev Owned, the row IS source-checked like any other: a proxy at an implementation the row
    ///      does not know fails stage 1 as a whole — the bound-admin row applied earlier in the same
    ///      stage is rolled back with it.
    function test_revertWhen_stage1OwnedForeignRowAtUnexpectedImplementation_noPartialCommit() public {
        _chainAdminMovesNotifier(implOther);
        _handNotifierAdminToExecutor();
        CTMTransition t = _deployTransitionWithForeignRow();
        _stage0(t);

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(notifierProxy), implOld, implOther)
        );
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(t)));

        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the bound-admin row must be rolled back");
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implOther, "the offending proxy is left where it was");
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version must not move");
        _assertPendingWithHold(t, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    // ─────────────────────────── post-state reads ───────────────────────────

    /// @dev A transparent proxy answers `implementation()` only to its own admin, so the bound
    ///      admin cannot even inspect the notifier; the post-state check reads the row through the
    ///      admin it names and therefore works for foreign rows.
    function test_validateTransitionApplied_readsForeignRowThroughItsOwnAdmin() public {
        CTMTransition t = _deployTransitionWithForeignRow();
        _prepareAndExecute(t);

        vm.expectRevert();
        ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(notifierProxy)));

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(notifierProxy), implNew, implOld)
        );
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(t)));

        _chainAdminMovesNotifier(implNew);
        // A view over live state — anyone may run the post-state check.
        vm.prank(makeAddr("stranger"));
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(t)));
    }
}

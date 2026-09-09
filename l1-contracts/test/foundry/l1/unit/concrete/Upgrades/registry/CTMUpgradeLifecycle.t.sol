// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {Utils} from "../../Utils/Utils.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/objects/ICoreRegistry.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IChainAssetHandlerBase} from "contracts/core/chain-asset-handler/IChainAssetHandler.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {
    CTMExecutorNotAuthorized,
    EcosystemExecutorProxyAdminMismatch,
    ZeroAddress,
    DeadlineNotYetPassed,
    EcosystemLegNotNamedByTransition,
    MigrationsNotPaused,
    NoPendingTransition,
    NotUpgradePauser,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch,
    TimerNotBoundToExecutor,
    TransitionNotPending,
    Unauthorized,
    UpgradeLifecycleBusy,
    UpgradeStageOutOfOrder
} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
    PinnedContract,
    ProxyUpgradeRow,
    TransitionManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @dev Three distinct implementations so a proxy row is a real `expectedOldImpl -> implNew`
///      edge and a proxy can also sit at an implementation the row does not know.
contract LifecycleImplOld {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract LifecycleImplNew {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract LifecycleImplOther {
    function version() external pure returns (uint256) {
        return 3;
    }
}

/// @dev Not a `CTMTransition`: exercises the executor's codehash provenance check at stage 0.
contract NotATransition {
    function manifestHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @notice The three-stage lifecycle of `CTMUpgradeExecutor` ({docs/upgrade-stage-lifecycle.md},
///         section 5): ordering and authority of the stages, the stage-0 join conditions, the
///         all-or-nothing stage 1, the checks-before-restoration stage 2, the CTM executor's
///         authority over the ecosystem leg, and how the executor's migration-pause hold composes
///         with other holds and the owner's pause on the fixture's real `L1ChainAssetHandler`.
/// @dev The "full" transition adds to the fixture's default a CTM-domain row (a proxy under the
///      executor's `ProxyAdmin`, in the `ValidatorTimelock` slot) and an ecosystem leg (a
///      `CoreRegistry` with one row over a proxy under the ecosystem executor's `ProxyAdmin`), so
///      both legs of stages 1 and 2 are exercised. The chain-side crossing (`upgradeChain`) with a
///      real upgrade engine is RegistryDrivenUpgrade.t.sol's business; the fixture engine is a
///      pinned stand-in.
contract CTMUpgradeLifecycleTest is CTMUpgradeExecutorFixture {
    address internal implOld;
    address internal implNew;
    address internal implOther;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    TransparentUpgradeableProxy internal ecosystemProxy;
    TransparentUpgradeableProxy internal otherEcosystemProxy;
    CoreRegistry internal coreRegistry;
    CoreRegistry internal otherCoreRegistry;

    function setUp() public override {
        super.setUp();
        implOld = address(new LifecycleImplOld());
        implNew = address(new LifecycleImplNew());
        implOther = address(new LifecycleImplOther());
        // One proxy per authority domain, each under the ProxyAdmin its executor owns.
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        otherEcosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        coreRegistry = _deployCoreRegistry(address(ecosystemProxy));
        otherCoreRegistry = _deployCoreRegistry(address(otherEcosystemProxy));
    }

    function test_replaceEcosystemExecutor_thenExecuteLifecycle() public {
        EcosystemUpgradeExecutor successor = new EcosystemUpgradeExecutor(
            governor,
            ecosystemProxyAdmin,
            ecosystemExecutor.CORE_REGISTRY_CODEHASH()
        );
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(ecosystemProxyAdmin),
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (address(successor)))
        });
        vm.startPrank(governor);
        ecosystemExecutor.forward(calls);
        successor.setCTMExecutorAuthorization(address(ctmExecutor), true);
        vm.expectEmit(true, true, false, false, address(ctmExecutor));
        emit CTMUpgradeExecutor.EcosystemExecutorChanged(address(ecosystemExecutor), address(successor));
        ctmExecutor.setEcosystemExecutor(successor);
        vm.stopPrank();
        assertEq(address(ctmExecutor.ECOSYSTEM_EXECUTOR()), address(successor));
        assertEq(ecosystemProxyAdmin.owner(), address(successor));
        CTMTransition full = _deployFullTransition();
        vm.startPrank(governor);
        ctmExecutor.stage0(full);
        ctmExecutor.stage1(full);
        ctmExecutor.stage2(full);
        vm.stopPrank();
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implNew
        );
        assertEq(address(ctmExecutor.pendingTransition()), address(0));
        assertFalse(chainAssetHandler.migrationPaused());
    }

    function test_rejectEcosystemReplacementDuringLifecycle() public {
        CTMTransition full = _deployFullTransition();
        vm.startPrank(governor);
        ctmExecutor.stage0(full);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(full)));
        ctmExecutor.setEcosystemExecutor(ecosystemExecutor);
        vm.stopPrank();
        assertEq(address(ctmExecutor.ECOSYSTEM_EXECUTOR()), address(ecosystemExecutor));
    }

    function test_rejectWrongEcosystemProxyAdmin() public {
        ProxyAdmin otherAdmin = new ProxyAdmin();
        EcosystemUpgradeExecutor other = new EcosystemUpgradeExecutor(
            governor,
            otherAdmin,
            ecosystemExecutor.CORE_REGISTRY_CODEHASH()
        );
        vm.expectRevert(
            abi.encodeWithSelector(
                EcosystemExecutorProxyAdminMismatch.selector,
                address(ecosystemProxyAdmin),
                address(otherAdmin)
            )
        );
        vm.prank(governor);
        ctmExecutor.setEcosystemExecutor(other);
        assertEq(address(ctmExecutor.ECOSYSTEM_EXECUTOR()), address(ecosystemExecutor));
    }

    function test_rejectZeroEcosystemExecutor() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(governor);
        ctmExecutor.setEcosystemExecutor(EcosystemUpgradeExecutor(payable(address(0))));
    }

    function test_rejectUnauthorizedEcosystemReplacement() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("unprivileged"));
        ctmExecutor.setEcosystemExecutor(ecosystemExecutor);
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _row(
        address _proxy,
        address _expectedOldImpl,
        address _implNew
    ) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: _pin(_implNew),
                callInitializeUpgrade: false,
                admin: ProxyAdmin(address(0))
            });
    }

    /// @dev A registry with one real edge (`implOld -> implNew`) on `_proxy`, in the L1Bridgehub
    ///      slot (the slot is a label — the row's own proxy address is its identity).
    function _deployCoreRegistry(address _proxy) internal returns (CoreRegistry) {
        CoreRegistryManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = _row(_proxy, implOld, implNew);
        return new CoreRegistry(manifest);
    }

    /// @dev The fixture's default manifest plus a CTM-domain row and the ecosystem leg.
    function _fullManifest() internal returns (TransitionManifest memory manifest) {
        manifest = _transitionManifest(777, chainContractAddress.currentRelease(), 0, L2_DELEGATE_CODE);
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(
            address(ctmDomainProxy),
            implOld,
            implNew
        );
        manifest.coreRegistry = _pin(address(coreRegistry));
    }

    function _deployFullTransition() internal returns (CTMTransition) {
        return new CTMTransition(_fullManifest());
    }

    function _liveImpl(ProxyAdmin _admin, TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return _admin.getProxyImplementation(ITransparentUpgradeableProxy(address(_proxy)));
    }

    function _singleCall(address _target, bytes memory _data) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
    }

    function _applyLegCall(ICoreRegistry _coreRegistry) internal view returns (Call[] memory) {
        return
            _singleCall(
                address(ecosystemExecutor),
                abi.encodeCall(EcosystemUpgradeExecutor.applyL1Upgrade, (_coreRegistry))
            );
    }

    function _moveProxyCall(TransparentUpgradeableProxy _proxy, address _impl) internal pure returns (bytes memory) {
        return abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(_proxy)), _impl));
    }

    /// @dev The lifecycle-slot and pause invariants that must hold while a transition is pending.
    function _assertPendingAndPaused(CTMTransition _transition, ICTMUpgradeExecutor.UpgradeStage _stage) internal view {
        assertEq(address(ctmExecutor.pendingTransition()), address(_transition), "the lifecycle must stay open");
        _assertStage(_stage);
        assertTrue(chainAssetHandler.migrationPaused(), "migrations must stay paused");
    }

    function _assertCtmUntouched() internal view {
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version must not move");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "no transition must be committed");
        assertEq(chainContractAddress.currentRelease(), address(fromRelease), "the release must not move");
    }

    function _assertLifecycleIdle() internal view {
        assertEq(address(ctmExecutor.pendingTransition()), address(0), "no transition may be recorded");
        _assertStage(ICTMUpgradeExecutor.UpgradeStage.None);
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_lifecycle_eventsAndEndState() public {
        CTMTransition full = _deployFullTransition();
        GovernanceUpgradeTimer timer = GovernanceUpgradeTimer(full.upgradeTimer());
        uint256 oldVersion = chainContractAddress.protocolVersion();
        assertFalse(chainAssetHandler.migrationPaused(), "fixture: migrations start unpaused");

        // Stage 0: migrations pause, the timer starts and the transition is recorded.
        vm.expectEmit(true, true, true, true, address(chainAssetHandler));
        emit IChainAssetHandlerBase.PausedMigration(address(ctmExecutor));
        vm.expectEmit(true, true, true, true, address(timer));
        emit GovernanceUpgradeTimer.TimerStarted(block.timestamp, block.timestamp);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.UpgradePrepared(address(full), block.timestamp);
        _stage0(full);

        _assertPendingAndPaused(full, ICTMUpgradeExecutor.UpgradeStage.Prepared);
        assertEq(timer.deadline(), block.timestamp, "a zero-delay timer is due in the same block");
        // Nothing moved yet.
        _assertCtmUntouched();
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld);
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld);

        // Stage 1: the ecosystem leg FIRST, then the CTM leg (rows, version commit, release pin).
        vm.expectEmit(true, true, true, true, address(ecosystemExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ecosystemProxy), implNew);
        vm.expectEmit(true, true, true, true, address(ecosystemExecutor));
        emit EcosystemUpgradeExecutor.L1UpgradeApplied(address(coreRegistry));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ctmDomainProxy), implNew);
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewProtocolVersion(oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.CTMUpgradeApplied(address(full), oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.UpgradeExecuted(address(full));
        _stage1(full);

        _assertPendingAndPaused(full, ICTMUpgradeExecutor.UpgradeStage.Executed);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.upgradeTransition(oldVersion), address(full));
        assertEq(chainContractAddress.currentRelease(), address(release));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the ecosystem row must be applied");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the CTM-domain row must be applied");

        // Stage 2: the applied-state checks pass, then restoration.
        vm.expectEmit(true, true, true, true, address(chainAssetHandler));
        emit IChainAssetHandlerBase.UnpausedMigration(address(ctmExecutor));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.UpgradeCompleted(address(full));
        _stage2(full);

        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPaused(), "stage 2 unpauses migrations");
        // The post-state checks keep holding on their own after completion.
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(full)));
        ecosystemExecutor.validateUpgradeApplied(ICoreRegistry(address(coreRegistry)));
    }

    // ─────────────────────────── ordering and authority ───────────────────────────

    function test_revertWhen_stage1NamesADifferentTransition() public {
        CTMTransition other = _deployTransition(778);
        _stage0(transition);

        vm.expectRevert(abi.encodeWithSelector(TransitionNotPending.selector, address(other), address(transition)));
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(other)));
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    function test_revertWhen_stage2NamesADifferentTransition() public {
        CTMTransition other = _deployTransition(778);
        _prepareAndExecute(transition);

        vm.expectRevert(abi.encodeWithSelector(TransitionNotPending.selector, address(other), address(transition)));
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(other)));
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Executed);
    }

    function test_revertWhen_stage1OrStage2BeforeStage0() public {
        vm.expectRevert(abi.encodeWithSelector(TransitionNotPending.selector, address(transition), address(0)));
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(transition)));

        vm.expectRevert(abi.encodeWithSelector(TransitionNotPending.selector, address(transition), address(0)));
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(transition)));
        _assertCtmUntouched();
    }

    function test_revertWhen_stage2SkipsStage1() public {
        _stage0(transition);

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeStageOutOfOrder.selector,
                uint8(ICTMUpgradeExecutor.UpgradeStage.Prepared),
                uint8(ICTMUpgradeExecutor.UpgradeStage.Executed)
            )
        );
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(transition)));
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Prepared);
        _assertCtmUntouched();
    }

    function test_revertWhen_stage1Repeated() public {
        _prepareAndExecute(transition);

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeStageOutOfOrder.selector,
                uint8(ICTMUpgradeExecutor.UpgradeStage.Executed),
                uint8(ICTMUpgradeExecutor.UpgradeStage.Prepared)
            )
        );
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(transition)));
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Executed);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the committed edge must stand");
    }

    function test_revertWhen_stage2Repeated() public {
        _runLifecycle(transition);

        // The slot is cleared by completion, so a replay finds nothing pending.
        vm.expectRevert(abi.encodeWithSelector(TransitionNotPending.selector, address(transition), address(0)));
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(transition)));
        assertFalse(chainAssetHandler.migrationPaused());
    }

    function test_revertWhen_stagesCalledByStranger() public {
        ICTMTransition t = ICTMTransition(address(transition));
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.stage0(t);
        _stage0(transition);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.stage1(t);
        _stage1(transition);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.stage2(t);
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Executed);
    }

    function test_revertWhen_stage0WhileAnotherTransitionIsPending() public {
        CTMTransition other = _deployTransition(778);
        _stage0(transition);

        // Busy at stage Prepared...
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(transition)));
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(other)));

        // ...and at stage Executed.
        _stage1(transition);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(transition)));
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(other)));
        assertTrue(chainAssetHandler.migrationPaused(), "the busy check must not disturb the pause");

        // Completion frees the slot: the next hop (departing from the new release and version)
        // prepares normally.
        _stage2(transition);
        address appliedRelease = address(release);
        release = _deployRelease(4);
        newVersion = SemVer.packSemVer(0, 2, 0);
        CTMTransition next = _deployTransitionFrom(880, appliedRelease, SemVer.packSemVer(0, 1, 0));
        _stage0(next);
        assertEq(address(ctmExecutor.pendingTransition()), address(next));
    }

    // ─────────────────────────── abandoning a stuck lifecycle ───────────────

    /// @dev A prepared transition whose stage 1 can never run (here: a CTM-domain row moved to an
    ///      unexpected implementation) is abandoned: the slot frees and a corrected transition
    ///      prepares normally. Migrations stay PAUSED — an abandoned lifecycle left the ecosystem
    ///      in an unintended state, so resuming them is governance's separate decision.
    function test_abandon_afterStage0_freesTheSlotAndLeavesMigrationsPaused() public {
        CTMTransition full = _deployFullTransition();
        _stage0(full);
        vm.prank(governor);
        ctmExecutor.forward(_singleCall(address(ctmProxyAdmin), _moveProxyCall(ctmDomainProxy, implOther)));
        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implOld, implOther)
        );
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(full)));

        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.UpgradeAbandoned(address(full), ICTMUpgradeExecutor.UpgradeStage.Prepared);
        vm.prank(governor);
        ctmExecutor.abandonPendingTransition();

        _assertLifecycleIdle();
        assertTrue(chainAssetHandler.migrationPaused(), "abandoning must not resume migrations");
        _assertCtmUntouched();
        // The corrected transition (the row now departs from where the proxy actually is).
        TransitionManifest memory corrected = _fullManifest();
        corrected.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(
            address(ctmDomainProxy),
            implOther,
            implNew
        );
        CTMTransition next = new CTMTransition(corrected);
        _stage0(next);
        _assertPendingAndPaused(next, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    /// @dev Abandoning after stage 1 is bookkeeping only: the edge stage 1 committed on the CTM
    ///      stands and the slot frees, with migrations still paused.
    function test_abandon_afterStage1_keepsTheCommittedEdge() public {
        uint256 oldVersion = chainContractAddress.protocolVersion();
        _stage0(transition);
        _stage1(transition);

        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.UpgradeAbandoned(address(transition), ICTMUpgradeExecutor.UpgradeStage.Executed);
        vm.prank(governor);
        ctmExecutor.abandonPendingTransition();

        _assertLifecycleIdle();
        assertTrue(chainAssetHandler.migrationPaused(), "abandoning must not resume migrations");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the committed version bump stands");
        assertEq(chainContractAddress.upgradeTransition(oldVersion), address(transition), "the commit stands");
        assertEq(chainContractAddress.currentRelease(), address(release), "the release pin stands");
    }

    /// @dev Abandoning touches the pause flag not at all, so it also works from an ecosystem the
    ///      owner already unpaused mid-lifecycle: only the lifecycle slot is cleared.
    function test_abandon_afterTheOwnerUnpaused_onlyFreesTheSlot() public {
        _stage0(transition);
        vm.prank(governor);
        chainAssetHandler.unpauseMigration();
        assertFalse(chainAssetHandler.migrationPaused());

        vm.prank(governor);
        ctmExecutor.abandonPendingTransition();

        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPaused(), "abandoning must not pause either");
    }

    function test_revertWhen_abandonWithoutAPendingTransition() public {
        vm.expectRevert(NoPendingTransition.selector);
        vm.prank(governor);
        ctmExecutor.abandonPendingTransition();
    }

    function test_revertWhen_abandonByStranger() public {
        _stage0(transition);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.abandonPendingTransition();
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    // ─────────────────────────── stage-0 join conditions ───────────────────────────

    function test_revertWhen_stage0TimerNotBoundToExecutor() public {
        // A timer someone else can start (bound to governance directly) is refused: stage 0
        // must be the only way this transition's clock starts.
        TransitionManifest memory manifest = _transitionManifest(
            777,
            chainContractAddress.currentRelease(),
            0,
            L2_DELEGATE_CODE
        );
        GovernanceUpgradeTimer unbound = new GovernanceUpgradeTimer(0, 0, governor, governor);
        manifest.upgradeTimer = _pin(address(unbound));
        CTMTransition mistimed = new CTMTransition(manifest);

        vm.expectRevert(abi.encodeWithSelector(TimerNotBoundToExecutor.selector, address(unbound), governor));
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(mistimed)));
        _assertLifecycleIdle();
        assertEq(unbound.deadline(), 0, "the timer must not have been started");
    }

    function test_revertWhen_stage0ExecutorNotRegisteredAsPauser() public {
        vm.prank(governor);
        chainAssetHandler.setUpgradePauser(address(ctmExecutor), false);

        vm.expectRevert(abi.encodeWithSelector(NotUpgradePauser.selector, address(ctmExecutor)));
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(transition)));
        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPaused());

        // The join is one owner call away.
        vm.prank(governor);
        chainAssetHandler.setUpgradePauser(address(ctmExecutor), true);
        _stage0(transition);
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    function test_revertWhen_stage0ExecutorNotAuthorizedOnEcosystemExecutor() public {
        vm.prank(governor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), false);

        // A join condition, checked whether or not this transition names an ecosystem leg.
        vm.expectRevert(abi.encodeWithSelector(CTMExecutorNotAuthorized.selector, address(ctmExecutor)));
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(transition)));
        _assertLifecycleIdle();

        vm.prank(governor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), true);
        _stage0(transition);
        _assertPendingAndPaused(transition, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    function test_revertWhen_stage0NamesANonGenuineCoreRegistry() public {
        // The transition's own pin holds (it pins whatever code sits at the address), so the
        // object constructs and validates; the executor still refuses a registry that does not
        // run the audited `CoreRegistry` code.
        address impostor = makeAddr("notACoreRegistry");
        vm.etch(impostor, hex"600046");
        TransitionManifest memory manifest = _fullManifest();
        manifest.coreRegistry = _pin(impostor);
        CTMTransition misnamed = new CTMTransition(manifest);
        misnamed.validate();

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                impostor,
                Utils.coreRegistryCodehash(),
                impostor.codehash
            )
        );
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(misnamed)));
        _assertLifecycleIdle();
    }

    function test_revertWhen_stage0WithNonGenuineTransition() public {
        NotATransition impostor = new NotATransition();

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(impostor),
                Utils.transitionCodehash(),
                address(impostor).codehash
            )
        );
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(impostor)));
        _assertLifecycleIdle();
    }

    // ─────────────────────────── stage-1 gates ───────────────────────────

    /// @dev The timer is the operational window between preparation and execution; its owner
    ///      (governance) keeps the bounded extension right through the timer itself.
    function test_stage1_waitsForTheTimerDeadline() public {
        TransitionManifest memory manifest = _transitionManifest(
            777,
            chainContractAddress.currentRelease(),
            0,
            L2_DELEGATE_CODE
        );
        GovernanceUpgradeTimer timer = _newTimer(100, 50);
        manifest.upgradeTimer = _pin(address(timer));
        CTMTransition delayed = new CTMTransition(manifest);
        uint256 preparedAt = block.timestamp;
        _stage0(delayed);
        assertEq(timer.deadline(), preparedAt + 100);

        vm.expectRevert(DeadlineNotYetPassed.selector);
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(delayed)));

        // Extended within the bound — the original deadline is no longer enough.
        vm.prank(governor);
        timer.changeDeadline(preparedAt + 120);
        vm.warp(preparedAt + 100);
        vm.expectRevert(DeadlineNotYetPassed.selector);
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(delayed)));
        _assertCtmUntouched();

        vm.warp(preparedAt + 120);
        _stage1(delayed);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
    }

    /// @dev Stage 1 reads the pause flag live rather than trusting that stage 0 set it: if the
    ///      owner unpauses in between, the commit refuses until migrations are paused again.
    ///      Recovering needs one owner call, and stage 2 then completes normally — with one flag,
    ///      stage 2 has nothing of its own to release.
    function test_revertWhen_stage1MigrationsNotPaused_afterTheOwnerUnpaused() public {
        _stage0(transition);
        vm.prank(governor);
        chainAssetHandler.unpauseMigration();
        assertFalse(chainAssetHandler.migrationPaused());

        vm.expectRevert(MigrationsNotPaused.selector);
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(transition)));
        _assertCtmUntouched();
        _assertStage(ICTMUpgradeExecutor.UpgradeStage.Prepared);

        // Pausing again makes the commit admissible.
        vm.prank(governor);
        chainAssetHandler.pauseMigration();
        _stage1(transition);
        assertEq(chainContractAddress.protocolVersion(), newVersion);

        _stage2(transition);
        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPaused(), "stage 2 unpauses migrations");
    }

    // ─────────────────────────── all-or-nothing stage 1 ───────────────────────────

    /// @dev A CTM-domain row whose proxy sits at an implementation the row does not know fails
    ///      the source check. The ecosystem leg ran FIRST inside the same stage, so "no partial
    ///      commit" means it is rolled back too.
    function test_revertWhen_stage1RowAtUnexpectedImplementation_noPartialCommit() public {
        CTMTransition full = _deployFullTransition();
        // Something moved the CTM-domain proxy on before the upgrade ran (an owner raw call
        // through the executor, which owns the admin).
        vm.prank(governor);
        ctmExecutor.forward(_singleCall(address(ctmProxyAdmin), _moveProxyCall(ctmDomainProxy, implOther)));
        // Stage 0 checks pins, not live implementations.
        _stage0(full);

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implOld, implOther)
        );
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(full)));

        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the ecosystem leg must be rolled back");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOther, "the offending proxy is left where it was");
        _assertCtmUntouched();
        _assertPendingAndPaused(full, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    // ─────────────────────────── checks before restoration ───────────────────────────

    function test_revertWhen_stage2CtmRowNoLongerApplied_keepsMigrationsPaused() public {
        CTMTransition full = _deployFullTransition();
        _prepareAndExecute(full);

        // Between stages 1 and 2 the CTM-domain proxy is moved off the row's target.
        vm.prank(governor);
        ctmExecutor.forward(_singleCall(address(ctmProxyAdmin), _moveProxyCall(ctmDomainProxy, implOther)));

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implNew, implOther)
        );
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(full)));
        _assertPendingAndPaused(full, ICTMUpgradeExecutor.UpgradeStage.Executed);
    }

    function test_revertWhen_stage2EcosystemRowNoLongerApplied_keepsMigrationsPaused() public {
        CTMTransition full = _deployFullTransition();
        _prepareAndExecute(full);

        // The ecosystem admin is owned by the ecosystem executor; its owner moves the proxy
        // through that executor's escape hatch.
        vm.prank(governor);
        ecosystemExecutor.forward(_singleCall(address(ecosystemProxyAdmin), _moveProxyCall(ecosystemProxy, implOther)));

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ecosystemProxy), implNew, implOther)
        );
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(full)));
        _assertPendingAndPaused(full, ICTMUpgradeExecutor.UpgradeStage.Executed);
    }

    // ─────────────────────────── cross-executor authority ───────────────────────────

    /// @dev The CTM executor may drive the ecosystem leg only for the registry its pending
    ///      transition names. Driven here through the executor's escape hatch (the ecosystem
    ///      executor sees the CTM executor as the caller), exactly the call stage 1 makes.
    function test_ecosystemLeg_onlyForTheRegistryThePendingTransitionNames() public {
        CTMTransition full = _deployFullTransition();
        _stage0(full);

        vm.expectRevert(
            abi.encodeWithSelector(EcosystemLegNotNamedByTransition.selector, address(full), address(otherCoreRegistry))
        );
        vm.prank(governor);
        ctmExecutor.forward(_applyLegCall(ICoreRegistry(address(otherCoreRegistry))));
        assertEq(_liveImpl(ecosystemProxyAdmin, otherEcosystemProxy), implOld);

        vm.prank(governor);
        ctmExecutor.forward(_applyLegCall(ICoreRegistry(address(coreRegistry))));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the named leg applies");
    }

    function test_revertWhen_ecosystemLegWithoutAPendingTransition() public {
        vm.expectRevert(
            abi.encodeWithSelector(EcosystemLegNotNamedByTransition.selector, address(0), address(coreRegistry))
        );
        vm.prank(governor);
        ctmExecutor.forward(_applyLegCall(ICoreRegistry(address(coreRegistry))));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld);
    }

    function test_revertWhen_ecosystemLegFromAnUnauthorizedExecutor() public {
        // Same code, same owner, bound to the same CTM — but never authorized by the ecosystem
        // executor's owner. Authorization is explicit wiring, never inferred from shape.
        CTMUpgradeExecutor stranger = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            new ProxyAdmin(),
            ecosystemExecutor,
            Utils.transitionCodehash()
        );

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(stranger)));
        vm.prank(governor);
        stranger.forward(_applyLegCall(ICoreRegistry(address(coreRegistry))));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld);
    }

    function test_ecosystemLeg_ownerStillAppliesDirectly() public {
        vm.expectEmit(true, true, true, true, address(ecosystemExecutor));
        emit EcosystemUpgradeExecutor.L1UpgradeApplied(address(coreRegistry));
        vm.prank(governor);
        ecosystemExecutor.applyL1Upgrade(ICoreRegistry(address(coreRegistry)));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew);
    }

    /// @dev Authorization is read live: revoked between stages 0 and 1, the ecosystem leg (and
    ///      with it the whole stage) is refused.
    function test_revertWhen_authorizationRevokedBeforeStage1() public {
        CTMTransition full = _deployFullTransition();
        _stage0(full);
        vm.prank(governor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), false);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(ctmExecutor)));
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(full)));
        _assertCtmUntouched();
        _assertPendingAndPaused(full, ICTMUpgradeExecutor.UpgradeStage.Prepared);
    }

    // ─────────────────────────── pause composition ───────────────────────────

    /// @dev EXPLICIT accepted behavior. There is ONE pause flag, so this lifecycle's stage 2
    ///      unpauses migrations even though a second upgrade still requires them paused.
    ///      Governance must not run overlapping upgrade lifecycles; the contract does not enforce
    ///      it, because per-executor holds would only have defended against accident and
    ///      governance already controls every executor.
    function test_stage2UnpausesEvenWhileAnotherUpgradeNeedsThePause() public {
        // A second upgrade (another CTM's executor) pauses across this whole lifecycle.
        address otherExecutor = makeAddr("otherCtmExecutor");
        vm.prank(governor);
        chainAssetHandler.setUpgradePauser(otherExecutor, true);
        vm.prank(otherExecutor);
        chainAssetHandler.pauseMigration();

        _runLifecycle(transition);

        assertFalse(
            chainAssetHandler.migrationPaused(),
            "one flag: this upgrade's completion lifts the pause the other upgrade still needs"
        );
    }

    /// @dev The same consequence for an owner-set pause: completion lifts it too, so an incident
    ///      pause must not be left to overlap an upgrade lifecycle.
    function test_stage2UnpausesTheOwnersPauseToo() public {
        vm.prank(governor);
        chainAssetHandler.pauseMigration();

        _runLifecycle(transition);

        assertFalse(chainAssetHandler.migrationPaused(), "one flag: completion lifts the owner's pause");
    }

    /// @dev And in the other direction: the owner's unpause mid-lifecycle really does unpause, so
    ///      stage 1 refuses until migrations are paused again
    ///      (see {test_revertWhen_stage1MigrationsNotPaused_afterTheOwnerUnpaused}).
    function test_ownerUnpauseDuringLifecycleUnpauses() public {
        _stage0(transition);
        assertTrue(chainAssetHandler.migrationPaused());

        vm.prank(governor);
        chainAssetHandler.unpauseMigration();
        assertFalse(chainAssetHandler.migrationPaused(), "one flag: the owner's unpause takes effect");
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
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
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {IEcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/IEcosystemUpgradeOperation.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/IEcosystemUpgradeExecutor.sol";
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
    CoordinatorNotBound,
    DeadlineNotYetPassed,
    LegNotReserved,
    MigrationsNotPaused,
    NoPendingOperation,
    NotCTMOwner,
    OperationNotPending,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch,
    TimerNotBoundToExecutor,
    Unauthorized,
    UpgradeLifecycleBusy,
    UpgradeStageOutOfOrder
} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
    CTMLeg,
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

/// @dev Not an `EcosystemUpgradeOperation`: exercises the coordinator's provenance check.
contract NotAnOperation {
    function manifestHash() external pure returns (bytes32) {
        return bytes32(uint256(2));
    }
}

/// @notice The three-stage lifecycle of one operation over one CTM, driven by the coordinator
///         ({protocol-docs/ecosystem-upgrade-coordination.md}): ordering and authority of the
///         stages, the stage-0 binding and provenance conditions, the all-or-nothing stage 1, the
///         checks-before-release stage 2, abandonment, coordinator replacement, and how the CTM's
///         own migration pause composes with the ecosystem pause on the fixture's real
///         `L1ChainAssetHandler`. Several CTMs under one operation are
///         EcosystemUpgradeCoordination.t.sol.
/// @dev The "full" transition adds to the fixture's default a CTM-domain row (a proxy under the
///      executor's `ProxyAdmin`, in the `ValidatorTimelock` slot), and its operation names an
///      ecosystem leg (a `CoreRegistry` with one row over a proxy under the core executor's
///      `ProxyAdmin`), so both legs of stages 1 and 2 are exercised. The chain-side crossing
///      (`upgradeChain`) with a real upgrade engine is RegistryDrivenUpgrade.t.sol's business; the
///      fixture engine is a pinned stand-in.
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

    /// @dev The fixture's default manifest plus a CTM-domain row.
    function _fullManifest() internal returns (TransitionManifest memory manifest) {
        manifest = _transitionManifest(777, chainContractAddress.currentRelease(), 0, L2_DELEGATE_CODE);
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(
            address(ctmDomainProxy),
            implOld,
            implNew
        );
    }

    /// @dev The full transition, registered under an operation that names the ecosystem leg.
    function _deployFullTransition() internal returns (CTMTransition full) {
        full = new CTMTransition(_fullManifest());
        _operationWithCore(ICTMTransition(address(full)), address(ctmExecutor), address(coreRegistry));
    }

    function _liveImpl(ProxyAdmin _admin, TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return _admin.getProxyImplementation(ITransparentUpgradeableProxy(address(_proxy)));
    }

    function _singleCall(address _target, bytes memory _data) internal pure returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
    }

    function _moveProxyCall(TransparentUpgradeableProxy _proxy, address _impl) internal pure returns (bytes memory) {
        return abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(_proxy)), _impl));
    }

    /// @dev The escape hatch is how governance reaches a CTM-scoped pause: the ChainAssetHandler
    ///      accepts only the CTM's owner, which is the executor, and governance owns the executor.
    function _forwardPauseCTM() internal {
        vm.prank(governor);
        ctmExecutor.forward(
            _singleCall(
                address(chainAssetHandler),
                abi.encodeCall(IChainAssetHandlerBase.pauseCTMMigration, (address(chainContractAddress)))
            )
        );
    }

    function _forwardUnpauseCTM() internal {
        vm.prank(governor);
        ctmExecutor.forward(
            _singleCall(
                address(chainAssetHandler),
                abi.encodeCall(IChainAssetHandlerBase.unpauseCTMMigration, (address(chainContractAddress)))
            )
        );
    }

    function _assertCtmUntouched() internal view {
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version must not move");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "no transition must be committed");
        assertEq(chainContractAddress.currentRelease(), address(fromRelease), "the release must not move");
    }

    /// @dev The lifecycle-slot, reservation and pause invariants that must hold while an
    ///      operation is pending.
    function _assertPendingAndPaused(CTMTransition _transition, IEcosystemUpgradeExecutor.UpgradeStage _stage) internal view {
        EcosystemUpgradeOperation operation = operationOf[address(_transition)];
        assertEq(address(coordinator.pendingOperation()), address(operation), "the lifecycle must stay open");
        _assertStage(_stage);
        assertEq(address(ctmExecutor.activeOperation()), address(operation), "the executor must stay reserved");
        assertEq(address(ctmExecutor.reservedTransition()), address(_transition), "the leg must stay reserved");
        assertTrue(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "migrations must stay paused");
    }

    function _assertLifecycleIdle() internal view {
        assertEq(address(coordinator.pendingOperation()), address(0), "no operation may be recorded");
        _assertStage(IEcosystemUpgradeExecutor.UpgradeStage.None);
        assertEq(address(ctmExecutor.activeOperation()), address(0), "the CTM executor must be free");
        assertEq(address(ctmExecutor.reservedTransition()), address(0), "no leg may stay reserved");
        assertEq(address(coreExecutor.activeOperation()), address(0), "the core executor must be free");
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_lifecycle_eventsAndEndState() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        GovernanceUpgradeTimer timer = GovernanceUpgradeTimer(full.upgradeTimer());
        uint256 oldVersion = chainContractAddress.protocolVersion();
        assertFalse(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "fixture: migrations start unpaused"
        );

        // Stage 0: the core leg is reserved, then the CTM leg — its migrations pause and its timer
        // starts — and the operation is recorded.
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.OperationReserved(address(operation), address(coreRegistry));
        vm.expectEmit(true, true, true, true, address(chainAssetHandler));
        emit IChainAssetHandlerBase.PausedCTMMigration(address(chainContractAddress), address(ctmExecutor));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.OperationReserved(address(operation), address(full));
        vm.expectEmit(true, true, true, true, address(timer));
        emit GovernanceUpgradeTimer.TimerStarted(block.timestamp, block.timestamp);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EcosystemUpgradeExecutor.OperationPrepared(address(operation));
        _stage0(full);

        _assertPendingAndPaused(full, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
        assertEq(address(coreExecutor.activeOperation()), address(operation), "the core executor is reserved");
        assertEq(address(coreExecutor.reservedCoreRegistry()), address(coreRegistry), "for the named registry");
        assertEq(timer.deadline(), block.timestamp, "a zero-delay timer is due in the same block");
        // Nothing moved yet.
        _assertCtmUntouched();
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld);
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld);

        // Stage 1: the ecosystem leg FIRST, then the CTM leg (rows, version commit, release pin).
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ecosystemProxy), implNew);
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.L1UpgradeApplied(address(coreRegistry));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ctmDomainProxy), implNew);
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewProtocolVersion(oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.CTMUpgradeApplied(address(full), oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EcosystemUpgradeExecutor.OperationExecuted(address(operation));
        _stage1(full);

        _assertPendingAndPaused(full, IEcosystemUpgradeExecutor.UpgradeStage.Executed);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.upgradeTransition(oldVersion), address(full));
        assertEq(chainContractAddress.currentRelease(), address(release));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the ecosystem row must be applied");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the CTM-domain row must be applied");

        // Stage 2: the applied-state checks pass, then every reservation and pause is released.
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.OperationEnded(address(operation));
        vm.expectEmit(true, true, true, true, address(chainAssetHandler));
        emit IChainAssetHandlerBase.UnpausedCTMMigration(address(chainContractAddress), address(ctmExecutor));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.OperationCompleted(address(operation));
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EcosystemUpgradeExecutor.OperationCompleted(address(operation));
        _stage2(full);

        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "stage 2 unpauses migrations");
        // The post-state checks keep holding on their own after completion.
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(full)));
        coreExecutor.validateUpgradeApplied(ICoreRegistry(address(coreRegistry)));
    }

    /// @dev The operation is the reviewable, queryable record of what was prepared.
    function test_operationManifestIsQueryable() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        assertEq(operation.coreRegistry(), address(coreRegistry));
        CTMLeg[] memory legs = operation.legs();
        assertEq(legs.length, 1);
        assertEq(legs[0].executor, address(ctmExecutor));
        assertEq(legs[0].transition, address(full));
        assertEq(operation.manifestHash(), keccak256(abi.encode(operation.getManifest())));
    }

    // ─────────────────────────── coordinator replacement ───────────────────────────

    function test_replaceCoordinator_thenExecuteLifecycle() public {
        EcosystemUpgradeExecutor successor = new EcosystemUpgradeExecutor(
            governor,
            coreExecutor,
            Utils.operationCodehash()
        );
        vm.startPrank(governor);
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.CoordinatorChanged(address(coordinator), address(successor));
        coreExecutor.setCoordinator(address(successor));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.CoordinatorChanged(address(coordinator), address(successor));
        ctmExecutor.setCoordinator(address(successor));
        vm.stopPrank();
        assertEq(coreExecutor.coordinator(), address(successor));
        assertEq(ctmExecutor.coordinator(), address(successor));

        // From here on the fixture drives (and binds timers to) the successor.
        coordinator = successor;
        CTMTransition full = _deployFullTransition();
        _runLifecycle(full);
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
    }

    /// @dev One operation is prepared, executed and completed by one coordinator: while either
    ///      domain is reserved, its binding cannot move.
    function test_rejectCoordinatorReplacementDuringLifecycle() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        _stage0(full);
        address successor = makeAddr("successor");

        vm.startPrank(governor);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(operation)));
        ctmExecutor.setCoordinator(successor);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(operation)));
        coreExecutor.setCoordinator(successor);
        vm.stopPrank();
        assertEq(ctmExecutor.coordinator(), address(coordinator));
        assertEq(coreExecutor.coordinator(), address(coordinator));

        // Free again after completion.
        _stage1(full);
        _stage2(full);
        vm.prank(governor);
        ctmExecutor.setCoordinator(successor);
        assertEq(ctmExecutor.coordinator(), successor);
    }

    function test_rejectUnauthorizedCoordinatorReplacement() public {
        vm.startPrank(makeAddr("unprivileged"));
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.setCoordinator(makeAddr("successor"));
        vm.expectRevert("Ownable: caller is not the owner");
        coreExecutor.setCoordinator(makeAddr("successor"));
        vm.stopPrank();
    }

    // ─────────────────────────── ordering and authority ───────────────────────────

    function test_revertWhen_stage1NamesADifferentOperation() public {
        EcosystemUpgradeOperation other = _operationFor(_deployTransition(778));
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _stage0(transition);

        vm.expectRevert(abi.encodeWithSelector(OperationNotPending.selector, address(other), address(operation)));
        vm.prank(governor);
        coordinator.stage1(other);
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
        _assertCtmUntouched();
    }

    function test_revertWhen_stage2NamesADifferentOperation() public {
        EcosystemUpgradeOperation other = _operationFor(_deployTransition(778));
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _prepareAndExecute(transition);

        vm.expectRevert(abi.encodeWithSelector(OperationNotPending.selector, address(other), address(operation)));
        vm.prank(governor);
        coordinator.stage2(other);
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Executed);
    }

    function test_revertWhen_stage1OrStage2BeforeStage0() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        vm.expectRevert(abi.encodeWithSelector(OperationNotPending.selector, address(operation), address(0)));
        vm.prank(governor);
        coordinator.stage1(operation);

        vm.expectRevert(abi.encodeWithSelector(OperationNotPending.selector, address(operation), address(0)));
        vm.prank(governor);
        coordinator.stage2(operation);
        _assertCtmUntouched();
        _assertLifecycleIdle();
    }

    function test_revertWhen_stage2SkipsStage1() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _stage0(transition);

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeStageOutOfOrder.selector,
                uint8(IEcosystemUpgradeExecutor.UpgradeStage.Prepared),
                uint8(IEcosystemUpgradeExecutor.UpgradeStage.Executed)
            )
        );
        vm.prank(governor);
        coordinator.stage2(operation);
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
        _assertCtmUntouched();
    }

    function test_revertWhen_stage1Repeated() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _prepareAndExecute(transition);

        vm.expectRevert(
            abi.encodeWithSelector(
                UpgradeStageOutOfOrder.selector,
                uint8(IEcosystemUpgradeExecutor.UpgradeStage.Executed),
                uint8(IEcosystemUpgradeExecutor.UpgradeStage.Prepared)
            )
        );
        vm.prank(governor);
        coordinator.stage1(operation);
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Executed);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the committed edge must stand");
    }

    function test_revertWhen_stage2Repeated() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _runLifecycle(transition);

        // The slot is cleared by completion, so a replay finds nothing pending.
        vm.expectRevert(abi.encodeWithSelector(OperationNotPending.selector, address(operation), address(0)));
        vm.prank(governor);
        coordinator.stage2(operation);
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
    }

    function test_revertWhen_stagesCalledByStranger() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        address stranger = makeAddr("stranger");

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        coordinator.stage0(operation);
        _stage0(transition);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        coordinator.stage1(operation);
        _stage1(transition);

        vm.prank(stranger);
        vm.expectRevert("Ownable: caller is not the owner");
        coordinator.stage2(operation);
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Executed);
    }

    function test_revertWhen_stage0WhileAnotherOperationIsPending() public {
        EcosystemUpgradeOperation other = _operationFor(_deployTransition(778));
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _stage0(transition);

        // Busy at stage Prepared...
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(operation)));
        vm.prank(governor);
        coordinator.stage0(other);

        // ...and at stage Executed.
        _stage1(transition);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(operation)));
        vm.prank(governor);
        coordinator.stage0(other);
        assertTrue(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "the busy check must not disturb the pause"
        );

        // Completion frees the slot: the next hop (departing from the new release and version)
        // prepares normally.
        _stage2(transition);
        address appliedRelease = address(release);
        release = _deployRelease(4);
        newVersion = SemVer.packSemVer(0, 2, 0);
        CTMTransition next = _deployTransitionFrom(880, appliedRelease, SemVer.packSemVer(0, 1, 0));
        _stage0(next);
        _assertPendingAndPaused(next, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
    }

    /// @dev A coordinator the domains do not name gets nothing — a shared owner and the same code
    ///      are not authorization. With a core leg the core executor's binding is checked first.
    function test_revertWhen_aForeignCoordinatorDrivesTheDomains() public {
        EcosystemUpgradeExecutor foreign = new EcosystemUpgradeExecutor(
            governor,
            coreExecutor,
            Utils.operationCodehash()
        );
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);

        vm.expectRevert(
            abi.encodeWithSelector(CoordinatorNotBound.selector, address(coreExecutor), address(coordinator))
        );
        vm.prank(governor);
        foreign.stage0(operation);

        EcosystemUpgradeOperation ctmOnly = _operationFor(transition);
        vm.expectRevert(
            abi.encodeWithSelector(CoordinatorNotBound.selector, address(ctmExecutor), address(coordinator))
        );
        vm.prank(governor);
        foreign.stage0(ctmOnly);

        // And the callbacks themselves refuse it outright.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(foreign)));
        vm.prank(address(foreign));
        ctmExecutor.beginOperation(ctmOnly, ICTMTransition(address(transition)));
        _assertLifecycleIdle();
        assertEq(address(foreign.pendingOperation()), address(0), "a refused stage 0 records nothing");
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
    }

    /// @dev The coordinator may apply exactly the leg it reserved: driven through its escape hatch
    ///      (the executor sees the coordinator as the caller), a different transition or operation
    ///      is refused.
    function test_revertWhen_coordinatorNamesAnUnreservedLeg() public {
        CTMTransition other = _deployTransition(778);
        EcosystemUpgradeOperation otherOperation = _operationFor(other);
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _stage0(transition);

        vm.expectRevert(abi.encodeWithSelector(LegNotReserved.selector, address(other), address(transition)));
        vm.prank(governor);
        coordinator.forward(
            _singleCall(
                address(ctmExecutor),
                abi.encodeCall(CTMUpgradeExecutor.applyTransition, (ICTMTransition(address(other))))
            )
        );
        vm.expectRevert(
            abi.encodeWithSelector(OperationNotPending.selector, address(otherOperation), address(operation))
        );
        vm.prank(governor);
        coordinator.forward(
            _singleCall(
                address(ctmExecutor),
                abi.encodeCall(CTMUpgradeExecutor.completeOperation, (IEcosystemUpgradeOperation(otherOperation)))
            )
        );
        _assertCtmUntouched();
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
    }

    // ─────────────────────────── abandoning a stuck lifecycle ───────────────

    /// @dev A prepared operation whose stage 1 can never run (here: a CTM-domain row moved to an
    ///      unexpected implementation) is abandoned: every reservation frees and a corrected
    ///      operation prepares normally. Migrations stay PAUSED — an abandoned lifecycle left the
    ///      ecosystem in an unintended state, so resuming them is governance's separate decision.
    function test_abandon_afterStage0_freesTheSlotAndLeavesMigrationsPaused() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        _stage0(full);
        vm.prank(governor);
        ctmExecutor.forward(_singleCall(address(ctmProxyAdmin), _moveProxyCall(ctmDomainProxy, implOther)));
        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implOld, implOther)
        );
        vm.prank(governor);
        coordinator.stage1(operation);

        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.OperationEnded(address(operation));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit CTMUpgradeExecutor.OperationAbandoned(address(operation));
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EcosystemUpgradeExecutor.OperationAbandoned(
            address(operation),
            IEcosystemUpgradeExecutor.UpgradeStage.Prepared
        );
        vm.prank(governor);
        coordinator.abandonPendingOperation();

        _assertLifecycleIdle();
        assertTrue(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "abandoning must not resume migrations"
        );
        _assertCtmUntouched();
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the ecosystem leg never ran");
        // The corrected transition (the row now departs from where the proxy actually is).
        TransitionManifest memory corrected = _fullManifest();
        corrected.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(
            address(ctmDomainProxy),
            implOther,
            implNew
        );
        CTMTransition next = new CTMTransition(corrected);
        _operationWithCore(ICTMTransition(address(next)), address(ctmExecutor), address(coreRegistry));
        _stage0(next);
        _assertPendingAndPaused(next, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
    }

    /// @dev Abandoning after stage 1 is bookkeeping only: the edge stage 1 committed on the CTM
    ///      stands and the slot frees, with migrations still paused.
    function test_abandon_afterStage1_keepsTheCommittedEdge() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        uint256 oldVersion = chainContractAddress.protocolVersion();
        _stage0(transition);
        _stage1(transition);

        vm.expectEmit(true, true, true, true, address(coordinator));
        emit EcosystemUpgradeExecutor.OperationAbandoned(
            address(operation),
            IEcosystemUpgradeExecutor.UpgradeStage.Executed
        );
        vm.prank(governor);
        coordinator.abandonPendingOperation();

        _assertLifecycleIdle();
        assertTrue(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "abandoning must not resume migrations"
        );
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the committed version bump stands");
        assertEq(chainContractAddress.upgradeTransition(oldVersion), address(transition), "the commit stands");
        assertEq(chainContractAddress.currentRelease(), address(release), "the release pin stands");
    }

    /// @dev Abandoning touches the pause not at all, so it also works from a CTM whose pause was
    ///      already lifted mid-lifecycle: only the reservations are cleared.
    /// @dev Lifting it needs the executor, since the pause is keyed by the CTM the executor owns.
    ///      Governance reaches that through the executor's owner-gated escape hatch.
    function test_abandon_afterTheCTMPauseWasLifted_onlyFreesTheSlot() public {
        _stage0(transition);
        _forwardUnpauseCTM();
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));

        vm.prank(governor);
        coordinator.abandonPendingOperation();

        _assertLifecycleIdle();
        assertFalse(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "abandoning must not pause either"
        );
    }

    function test_revertWhen_abandonWithoutAPendingOperation() public {
        vm.expectRevert(NoPendingOperation.selector);
        vm.prank(governor);
        coordinator.abandonPendingOperation();
    }

    function test_revertWhen_abandonByStranger() public {
        _stage0(transition);
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
        coordinator.abandonPendingOperation();
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
    }

    // ─────────────────────────── stage-0 conditions ───────────────────────────

    function test_revertWhen_stage0TimerNotBoundToCoordinator() public {
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
        EcosystemUpgradeOperation operation = _operationFor(mistimed);

        vm.expectRevert(abi.encodeWithSelector(TimerNotBoundToExecutor.selector, address(unbound), governor));
        vm.prank(governor);
        coordinator.stage0(operation);
        _assertLifecycleIdle();
        assertEq(unbound.deadline(), 0, "the timer must not have been started");
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "nothing stays paused");
    }

    /// @dev The pause authority is DERIVED from CTM ownership, so there is no registration to
    ///      forget — but an executor that does not (yet) own its CTM cannot pause it, which is
    ///      exactly the pre-bootstrap state. Stage 0 therefore fails until the handover is done.
    function test_revertWhen_stage0BeforeTheExecutorOwnsItsCTM() public {
        // Hand the CTM back to governance: the executor is bound to it but no longer owns it.
        vm.prank(address(ctmExecutor));
        Ownable2Step(address(chainContractAddress)).transferOwnership(governor);
        vm.prank(governor);
        Ownable2Step(address(chainContractAddress)).acceptOwnership();
        EcosystemUpgradeOperation operation = _operationFor(transition);

        vm.expectRevert(
            abi.encodeWithSelector(NotCTMOwner.selector, address(ctmExecutor), address(chainContractAddress))
        );
        vm.prank(governor);
        coordinator.stage0(operation);
        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));
    }

    /// @dev Each domain's binding is read live at stage 0: a detached executor is refused, whether
    ///      or not the operation names an ecosystem leg.
    function test_revertWhen_stage0DomainDoesNotNameTheCoordinator() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        vm.prank(governor);
        ctmExecutor.setCoordinator(address(0));

        vm.expectRevert(abi.encodeWithSelector(CoordinatorNotBound.selector, address(ctmExecutor), address(0)));
        vm.prank(governor);
        coordinator.stage0(operation);
        _assertLifecycleIdle();

        vm.prank(governor);
        ctmExecutor.setCoordinator(address(coordinator));
        _stage0(transition);
        _assertPendingAndPaused(transition, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
    }

    function test_revertWhen_stage0CoreExecutorDoesNotNameTheCoordinator() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        vm.prank(governor);
        coreExecutor.setCoordinator(address(0));

        vm.expectRevert(abi.encodeWithSelector(CoordinatorNotBound.selector, address(coreExecutor), address(0)));
        vm.prank(governor);
        coordinator.stage0(operation);
        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "no leg was reserved");
    }

    function test_revertWhen_stage0NamesANonGenuineCoreRegistry() public {
        // The operation names whatever address it is given; the core executor refuses a registry
        // that does not run the audited `CoreRegistry` code when asked to reserve it.
        address impostor = makeAddr("notACoreRegistry");
        vm.etch(impostor, hex"600046");
        EcosystemUpgradeOperation misnamed = _operationWithCore(
            ICTMTransition(address(transition)),
            address(ctmExecutor),
            impostor
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                impostor,
                Utils.coreRegistryCodehash(),
                impostor.codehash
            )
        );
        vm.prank(governor);
        coordinator.stage0(misnamed);
        _assertLifecycleIdle();
    }

    function test_revertWhen_stage0WithNonGenuineTransition() public {
        NotATransition impostor = new NotATransition();
        EcosystemUpgradeOperation operation = _operationFor(ICTMTransition(address(impostor)), address(ctmExecutor));

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(impostor),
                Utils.transitionCodehash(),
                address(impostor).codehash
            )
        );
        vm.prank(governor);
        coordinator.stage0(operation);
        _assertLifecycleIdle();
    }

    function test_revertWhen_stage0WithNonGenuineOperation() public {
        NotAnOperation impostor = new NotAnOperation();

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(impostor),
                Utils.operationCodehash(),
                address(impostor).codehash
            )
        );
        vm.prank(governor);
        coordinator.stage0(IEcosystemUpgradeOperation(address(impostor)));
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
        EcosystemUpgradeOperation operation = _operationFor(delayed);
        uint256 preparedAt = block.timestamp;
        _stage0(delayed);
        assertEq(timer.deadline(), preparedAt + 100);

        vm.expectRevert(DeadlineNotYetPassed.selector);
        vm.prank(governor);
        coordinator.stage1(operation);

        // Extended within the bound — the original deadline is no longer enough.
        vm.prank(governor);
        timer.changeDeadline(preparedAt + 120);
        vm.warp(preparedAt + 100);
        vm.expectRevert(DeadlineNotYetPassed.selector);
        vm.prank(governor);
        coordinator.stage1(operation);
        _assertCtmUntouched();

        vm.warp(preparedAt + 120);
        _stage1(delayed);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
    }

    /// @dev Stage 1 reads the pause live rather than trusting that stage 0 set it: if this CTM's
    ///      pause is lifted in between, the commit refuses until it is paused again.
    function test_revertWhen_stage1MigrationsNotPaused_afterTheCTMPauseWasLifted() public {
        EcosystemUpgradeOperation operation = _operationFor(transition);
        _stage0(transition);
        _forwardUnpauseCTM();
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)));

        vm.expectRevert(MigrationsNotPaused.selector);
        vm.prank(governor);
        coordinator.stage1(operation);
        _assertCtmUntouched();
        _assertStage(IEcosystemUpgradeExecutor.UpgradeStage.Prepared);

        // Pausing this CTM again makes the commit admissible.
        _forwardPauseCTM();
        _stage1(transition);
        assertEq(chainContractAddress.protocolVersion(), newVersion);

        _stage2(transition);
        _assertLifecycleIdle();
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "stage 2 unpauses migrations");
    }

    // ─────────────────────────── all-or-nothing stage 1 ───────────────────────────

    /// @dev A CTM-domain row whose proxy sits at an implementation the row does not know fails
    ///      the source check. The ecosystem leg ran FIRST inside the same stage, so "no partial
    ///      commit" means it is rolled back too.
    function test_revertWhen_stage1RowAtUnexpectedImplementation_noPartialCommit() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
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
        coordinator.stage1(operation);

        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the ecosystem leg must be rolled back");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOther, "the offending proxy is left where it was");
        _assertCtmUntouched();
        _assertPendingAndPaused(full, IEcosystemUpgradeExecutor.UpgradeStage.Prepared);
    }

    // ─────────────────────────── checks before release ───────────────────────────

    function test_revertWhen_stage2CtmRowNoLongerApplied_keepsMigrationsPaused() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        _prepareAndExecute(full);

        // Between stages 1 and 2 the CTM-domain proxy is moved off the row's target.
        vm.prank(governor);
        ctmExecutor.forward(_singleCall(address(ctmProxyAdmin), _moveProxyCall(ctmDomainProxy, implOther)));

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implNew, implOther)
        );
        vm.prank(governor);
        coordinator.stage2(operation);
        _assertPendingAndPaused(full, IEcosystemUpgradeExecutor.UpgradeStage.Executed);
        assertEq(address(coreExecutor.activeOperation()), address(operation), "the core reservation holds too");
    }

    function test_revertWhen_stage2EcosystemRowNoLongerApplied_keepsMigrationsPaused() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        _prepareAndExecute(full);

        // The ecosystem admin is owned by the core executor; its owner moves the proxy through
        // that executor's escape hatch.
        vm.prank(governor);
        coreExecutor.forward(_singleCall(address(ecosystemProxyAdmin), _moveProxyCall(ecosystemProxy, implOther)));

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ecosystemProxy), implNew, implOther)
        );
        vm.prank(governor);
        coordinator.stage2(operation);
        _assertPendingAndPaused(full, IEcosystemUpgradeExecutor.UpgradeStage.Executed);
    }

    /// @dev The owner path of the core executor is unaffected by the coordinator: the bootstrap
    ///      edge and recovery apply a registry directly.
    function test_ecosystemLeg_ownerStillAppliesDirectly() public {
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.L1UpgradeApplied(address(coreRegistry));
        vm.prank(governor);
        coreExecutor.applyL1Upgrade(ICoreRegistry(address(coreRegistry)));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew);
    }

    // ─────────────────────────── pause composition ───────────────────────────

    /// @dev The separation the per-CTM pause buys: an ECOSYSTEM pause is incident control and a
    ///      completing upgrade must not lift it. (One CTM's pause being independent of another's
    ///      is proved directly, with two CTMs, in `L1ChainAssetHandlerMigrationPause.t.sol`.)
    function test_stage2LeavesTheEcosystemPauseInPlace() public {
        vm.prank(governor);
        chainAssetHandler.pauseMigration();

        _runLifecycle(transition);

        assertFalse(
            chainAssetHandler.ctmMigrationPaused(address(chainContractAddress)),
            "stage 2 lifts this CTM's own pause"
        );
        assertTrue(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "but the ecosystem pause is not an upgrade's to lift"
        );
    }

    /// @dev And the converse: lifting the ecosystem pause mid-lifecycle does not resume this CTM,
    ///      because stage 0 paused the CTM itself.
    function test_ecosystemUnpauseDuringLifecycleLeavesTheCTMPaused() public {
        vm.prank(governor);
        chainAssetHandler.pauseMigration();
        _stage0(transition);

        vm.prank(governor);
        chainAssetHandler.unpauseMigration();
        assertTrue(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "stage 0's own pause survives the ecosystem unpause"
        );

        // So the commit is still admissible and the lifecycle completes normally.
        _stage1(transition);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        _stage2(transition);
        _assertLifecycleIdle();
    }
}

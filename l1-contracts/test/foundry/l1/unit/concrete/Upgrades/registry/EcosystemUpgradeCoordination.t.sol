// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {LifecycleImplNew, LifecycleImplOld} from "./CTMUpgradeLifecycle.t.sol";
import {Utils} from "../../Utils/Utils.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/IEcosystemUpgradeExecutor.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {ChainTypeManager} from "contracts/state-transition/ChainTypeManager.sol";
import {IChainTypeManager, ChainTypeManagerInitializeData} from "contracts/state-transition/IChainTypeManager.sol";
import {
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {
    DuplicateOperationLeg,
    EmptyOperation,
    L2BytecodeNotPublished,
    OperationNotPending,
    ProxyUpgradeRowMismatch,
    Unauthorized,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
    CTMLeg,
    ProxyUpgradeRow,
    TransitionManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice One operation over SEVERAL CTMs sharing one ecosystem change — the case the
///         coordinator exists for ({protocol-docs/ecosystem-upgrade-coordination.md}): the
///         operation's shape rules, the reservation of every participant before anything is
///         applied, the core leg applied once ahead of the CTM legs in committed order, a later
///         leg's failure rolling back the core and the earlier legs, completion releasing no pause
///         before every leg verified, and abandonment across all participants.
/// @dev Builds on the one-CTM fixture by deploying a SECOND real ZKsyncOS CTM behind the same
///      implementation (registered on the fixture's real Bridgehub, its own executor and
///      `ProxyAdmin`, its own current release pin) so both legs run real CTM commits against the
///      fixture's real `L1ChainAssetHandler`. Neither CTM crosses a chain here — that is
///      RegistryDrivenUpgrade.t.sol's business.
contract EcosystemUpgradeCoordinationTest is CTMUpgradeExecutorFixture {
    ChainTypeManager internal ctm2;
    CTMUpgradeExecutor internal ctmExecutor2;
    ProxyAdmin internal ctmProxyAdmin2;

    address internal implOld;
    address internal implNew;
    TransparentUpgradeableProxy internal ecosystemProxy;
    CoreRegistry internal coreRegistry;

    function setUp() public override {
        super.setUp();

        // The second CTM: same implementation and genesis shape as the fixture's, registered on
        // the Bridgehub (the ChainAssetHandler derives pause authority from registration plus
        // ownership), handed to its own executor and re-pointed at the same real release.
        ctm2 = ChainTypeManager(
            address(
                new TransparentUpgradeableProxy(
                    address(chainTypeManager),
                    admin,
                    abi.encodeCall(
                        IChainTypeManager.initialize,
                        ChainTypeManagerInitializeData({
                            owner: governor,
                            validatorTimelock: validator,
                            releaseCodehash: Utils.releaseCodehash(),
                            currentRelease: Utils.TEST_GENESIS_REGISTRY,
                            protocolVersion: 0,
                            serverNotifier: serverNotifier
                        })
                    )
                )
            )
        );
        vm.prank(governor);
        bridgehub.addChainTypeManager(address(ctm2));
        ctmProxyAdmin2 = new ProxyAdmin();
        ctmExecutor2 = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(ctm2)),
            ctmProxyAdmin2,
            address(coordinator),
            Utils.transitionCodehash()
        );
        ctmProxyAdmin2.transferOwnership(address(ctmExecutor2));
        vm.prank(governor);
        ctm2.transferOwnership(address(ctmExecutor2));
        ctmExecutor2.acceptCTMOwnership();
        Call[] memory repoint = new Call[](1);
        repoint[0] = Call({
            target: address(ctm2),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (address(fromRelease)))
        });
        vm.prank(governor);
        ctmExecutor2.forward(repoint);
        assertEq(ctm2.currentRelease(), address(fromRelease));

        // The shared ecosystem change: one proxy under the core executor's admin.
        implOld = address(new LifecycleImplOld());
        implNew = address(new LifecycleImplNew());
        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        CoreRegistryManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implOld,
            implNew: _pin(implNew),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        coreRegistry = new CoreRegistry(manifest);
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _leg(CTMUpgradeExecutor _executor, CTMTransition _transition) internal pure returns (CTMLeg memory) {
        return CTMLeg({executor: address(_executor), transition: address(_transition)});
    }

    /// @dev The two-leg operation over the fixture CTM (leg 0) and the second CTM (leg 1), with
    ///      the shared ecosystem leg.
    function _twoLegOperation(
        CTMTransition _first,
        CTMTransition _second
    ) internal returns (EcosystemUpgradeOperation) {
        CTMLeg[] memory legs = new CTMLeg[](2);
        legs[0] = _leg(ctmExecutor, _first);
        legs[1] = _leg(ctmExecutor2, _second);
        return _deployOperation(address(coreRegistry), legs);
    }

    function _liveEcosystemImpl() internal view returns (address) {
        return ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy)));
    }

    function _assertBothPaused(bool _paused) internal view {
        assertEq(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), _paused, "CTM 1 pause");
        assertEq(chainAssetHandler.migrationPausedFor(address(ctm2)), _paused, "CTM 2 pause");
    }

    function _assertBothUntouched() internal view {
        assertEq(chainContractAddress.protocolVersion(), 0, "CTM 1 version must not move");
        assertEq(ctm2.protocolVersion(), 0, "CTM 2 version must not move");
        assertEq(_liveEcosystemImpl(), implOld, "the ecosystem leg must not be applied");
    }

    function _assertAllFree() internal view {
        assertEq(address(coordinator.pendingOperation()), address(0), "the coordinator must be idle");
        assertEq(address(coreExecutor.activeOperation()), address(0), "the core executor must be free");
        assertEq(address(ctmExecutor.activeOperation()), address(0), "CTM executor 1 must be free");
        assertEq(address(ctmExecutor2.activeOperation()), address(0), "CTM executor 2 must be free");
    }

    // ─────────────────────────────── the shared upgrade ───────────────────────────────

    function test_twoCtmsShareOneCoreLeg_endToEnd() public {
        CTMTransition first = _deployTransition(777);
        CTMTransition second = _deployTransition(778);
        EcosystemUpgradeOperation operation = _twoLegOperation(first, second);

        vm.prank(governor);
        coordinator.stage0(operation);
        _assertBothPaused(true);
        assertEq(address(coreExecutor.reservedCoreRegistry()), address(coreRegistry));
        assertEq(address(ctmExecutor.reservedTransition()), address(first));
        assertEq(address(ctmExecutor2.reservedTransition()), address(second));
        assertEq(GovernanceUpgradeTimer(first.upgradeTimer()).deadline(), block.timestamp, "timer 1 started");
        assertEq(GovernanceUpgradeTimer(second.upgradeTimer()).deadline(), block.timestamp, "timer 2 started");
        _assertBothUntouched();

        vm.prank(governor);
        coordinator.stage1(operation);
        assertEq(_liveEcosystemImpl(), implNew, "the ecosystem leg applies once, ahead of the CTM legs");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "CTM 1 committed");
        assertEq(ctm2.protocolVersion(), newVersion, "CTM 2 committed");
        assertEq(chainContractAddress.upgradeTransition(0), address(first));
        assertEq(ctm2.upgradeTransition(0), address(second));
        assertEq(ctm2.currentRelease(), address(release));
        _assertBothPaused(true);

        vm.prank(governor);
        coordinator.stage2(operation);
        _assertBothPaused(false);
        _assertAllFree();
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(first)));
        ctmExecutor2.validateTransitionApplied(ICTMTransition(address(second)));
    }

    /// @dev Legs may share ONE `GovernanceUpgradeTimer` — the prepare deploys one clock per
    ///      upgrade, not one per CTM. Stage 0 must start it exactly once: a second `startTimer()`
    ///      reverts `TimerAlreadyStarted`, so the stage completing at all is the assertion.
    function test_legsSharingOneTimer_startItExactlyOnce() public {
        GovernanceUpgradeTimer shared = _newTimer(0, 0);
        CTMTransition first = _transitionWithTimer(777, shared);
        CTMTransition second = _transitionWithTimer(778, shared);
        assertEq(first.upgradeTimer(), second.upgradeTimer(), "both legs pin the same clock");
        EcosystemUpgradeOperation operation = _twoLegOperation(first, second);

        vm.prank(governor);
        coordinator.stage0(operation);

        assertEq(shared.deadline(), block.timestamp, "the shared clock runs");
        _assertBothPaused(true);

        // Stage 1 gates both legs on that one deadline.
        vm.prank(governor);
        coordinator.stage1(operation);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "CTM 1 committed");
        assertEq(ctm2.protocolVersion(), newVersion, "CTM 2 committed");
    }

    /// @dev A fixture transition re-pinned onto `_timer` instead of its own fresh one.
    function _transitionWithTimer(
        uint256 _upgradeTimestamp,
        GovernanceUpgradeTimer _timer
    ) internal returns (CTMTransition) {
        TransitionManifest memory manifest = _transitionManifest(
            _upgradeTimestamp,
            address(fromRelease),
            0,
            L2_DELEGATE_CODE
        );
        manifest.upgradeTimer = _pin(address(_timer));
        return new CTMTransition(manifest);
    }

    /// @dev Stage 1 is one transaction: the second leg failing (its factory dependency is not
    ///      published on the shared supplier) rolls back the core leg and the first CTM leg with
    ///      it, and every reservation and pause stays in place for a retry.
    function test_laterLegFailureRollsBackTheCoreAndEarlierLegs() public {
        CTMTransition first = _deployTransition(777);
        bytes memory unpublishedDelegate = hex"de1f";
        CTMTransition second = _deployTransitionWithDelegate(778, address(fromRelease), 0, unpublishedDelegate);
        EcosystemUpgradeOperation operation = _twoLegOperation(first, second);
        vm.prank(governor);
        coordinator.stage0(operation);

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(unpublishedDelegate)));
        vm.prank(governor);
        coordinator.stage1(operation);

        _assertBothUntouched();
        _assertBothPaused(true);
        assertEq(address(coordinator.pendingOperation()), address(operation), "the operation stays prepared");
        assertTrue(coordinator.pendingStage() == IEcosystemUpgradeExecutor.UpgradeStage.Prepared);

        // Published, the same operation executes with nothing else changed.
        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(unpublishedDelegate));
        vm.startPrank(governor);
        coordinator.stage1(operation);
        coordinator.stage2(operation);
        vm.stopPrank();
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(ctm2.protocolVersion(), newVersion);
        _assertAllFree();
    }

    /// @dev Stage 2 is one transaction: a later CTM's foreign-admin row still waiting for its
    ///      administrator rolls back the core's and the first CTM's release too.
    function test_stage2ReleasesNothingUntilEveryLegVerified() public {
        // A per-CTM proxy of the second CTM under an admin the executor does not own.
        address chainAdmin = makeAddr("chainAdmin");
        ProxyAdmin notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(chainAdmin);
        TransparentUpgradeableProxy notifierProxy = new TransparentUpgradeableProxy(
            implOld,
            address(notifierAdmin),
            hex""
        );
        TransitionManifest memory manifest = _transitionManifest(778, address(fromRelease), 0, L2_DELEGATE_CODE);
        manifest.proxyUpgrades[uint256(CTMContract.ServerNotifier)] = ProxyUpgradeRow({
            proxy: address(notifierProxy),
            expectedOldImpl: implOld,
            implNew: _pin(implNew),
            callInitializeUpgrade: false,
            admin: notifierAdmin
        });
        CTMTransition first = _deployTransition(777);
        CTMTransition second = new CTMTransition(manifest);
        EcosystemUpgradeOperation operation = _twoLegOperation(first, second);
        vm.startPrank(governor);
        coordinator.stage0(operation);
        coordinator.stage1(operation);
        vm.stopPrank();
        assertEq(ctm2.protocolVersion(), newVersion, "the leg otherwise completes");

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(notifierProxy), implNew, implOld)
        );
        vm.prank(governor);
        coordinator.stage2(operation);
        _assertBothPaused(true);
        assertEq(address(ctmExecutor.activeOperation()), address(operation), "CTM 1 stays reserved");
        assertEq(address(coreExecutor.activeOperation()), address(operation), "the core stays reserved");

        vm.prank(chainAdmin);
        notifierAdmin.upgrade(ITransparentUpgradeableProxy(address(notifierProxy)), implNew);
        vm.prank(governor);
        coordinator.stage2(operation);
        _assertBothPaused(false);
        _assertAllFree();
    }

    function test_abandon_releasesEveryReservationAndLeavesEveryPause() public {
        CTMTransition first = _deployTransition(777);
        CTMTransition second = _deployTransition(778);
        EcosystemUpgradeOperation operation = _twoLegOperation(first, second);
        vm.prank(governor);
        coordinator.stage0(operation);

        vm.prank(governor);
        coordinator.abandonPendingOperation();

        _assertAllFree();
        _assertBothPaused(true);
        _assertBothUntouched();
    }

    // ─────────────────────────── participants and authority ───────────────────────────

    /// @dev A leg whose executor does not name this coordinator refuses the whole stage 0 —
    ///      including the legs and the core leg reserved before it.
    function test_revertWhen_aLaterLegDoesNotNameTheCoordinator() public {
        CTMTransition first = _deployTransition(777);
        CTMTransition second = _deployTransition(778);
        EcosystemUpgradeOperation operation = _twoLegOperation(first, second);
        address other = makeAddr("otherCoordinator");
        vm.prank(governor);
        ctmExecutor2.setCoordinator(other);

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(coordinator)));
        vm.prank(governor);
        coordinator.stage0(operation);
        _assertAllFree();
        _assertBothPaused(false);
    }

    function test_revertWhen_operationDiffersBetweenStages() public {
        CTMTransition first = _deployTransition(777);
        CTMTransition second = _deployTransition(778);
        EcosystemUpgradeOperation both = _twoLegOperation(first, second);
        // The same legs under another object — the object, not its content, is what was prepared.
        EcosystemUpgradeOperation twin = _twoLegOperation(first, second);
        assertEq(both.manifestHash(), twin.manifestHash(), "identical manifests commit identically");
        vm.prank(governor);
        coordinator.stage0(both);

        vm.expectRevert(abi.encodeWithSelector(OperationNotPending.selector, address(twin), address(both)));
        vm.prank(governor);
        coordinator.stage1(twin);
        _assertBothUntouched();
    }

    function test_revertWhen_operationNamesOneCtmTwice() public {
        CTMTransition first = _deployTransition(777);
        CTMTransition again = _deployTransition(778);
        CTMLeg[] memory legs = new CTMLeg[](2);
        legs[0] = _leg(ctmExecutor, first);
        legs[1] = _leg(ctmExecutor, again);
        vm.expectRevert(abi.encodeWithSelector(DuplicateOperationLeg.selector, address(chainContractAddress)));
        _deployOperation(address(coreRegistry), legs);

        // Two executors bound to the same CTM are the same duplicate.
        CTMUpgradeExecutor twinExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            new ProxyAdmin(),
            address(coordinator),
            Utils.transitionCodehash()
        );
        legs[1] = _leg(twinExecutor, again);
        vm.expectRevert(abi.encodeWithSelector(DuplicateOperationLeg.selector, address(chainContractAddress)));
        _deployOperation(address(coreRegistry), legs);
    }

    function test_revertWhen_operationHasNoLegs() public {
        // A core-only change rides a schedule-only transition on one CTM instead.
        vm.expectRevert(EmptyOperation.selector);
        _deployOperation(address(coreRegistry), new CTMLeg[](0));
    }

    function test_revertWhen_legNamesZeroAddresses() public {
        CTMLeg[] memory legs = new CTMLeg[](1);
        legs[0] = CTMLeg({executor: address(0), transition: address(transition)});
        vm.expectRevert(ZeroAddress.selector);
        _deployOperation(address(0), legs);
        legs[0] = CTMLeg({executor: address(ctmExecutor), transition: address(0)});
        vm.expectRevert(ZeroAddress.selector);
        _deployOperation(address(0), legs);
    }
}

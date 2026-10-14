// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Call} from "contracts/governance/Common.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {UpgradeExecutorBase} from "contracts/governance/UpgradeExecutorBase.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CoreTransition} from "contracts/upgrades/registry/objects/CoreTransition.sol";
import {ICoreTransition} from "contracts/upgrades/registry/objects/ICoreTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {RegistryBootstrapSequence} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapSequence.sol";
import {BootstrapAction} from "contracts/upgrades/registry/bootstrap/IRegistryBootstrapSequence.sol";
import {
    BootstrapAuthorityNotHeld,
    BootstrapNominationPending,
    BootstrapNotYetExecuted,
    MigrationPaused,
    RegistryTargetHasNoCode,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    AuthoredL2Plan,
    BootstrapManifest,
    CoreTransitionManifest,
    GenesisFacet,
    ProxyUpgradeRow,
    ReleaseGenesisData,
    ReleaseManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {LegacyBootstrapSequence} from "./_LegacyBootstrapSequence.t.sol";

/// @dev Two distinct implementations, so every proxy row is a real `expectedOldImpl -> implNew`
///      edge rather than a no-op.
contract SeqImplOld {
    function version() external pure returns (uint256) {
        return 33;
    }
}

contract SeqImplNew {
    function version() external pure returns (uint256) {
        return 34;
    }
}

/// @notice Tests that the bootstrap edge's governance sequence is DERIVED from the objects the
///         edge already deploys, and that the derivation is the same sequence the two v35 prepare
///         scripts used to author by hand (see {LegacyBootstrapSequence}).
/// @dev Driven against real objects throughout — a real `ChainTypeManager`, real OpenZeppelin
///      `ProxyAdmin`s for both domains, a real `CoreTransition` and a real
///      `RegistryBootstrapMigration` — because the property under test is the derivation, and a
///      mocked object would be deriving from the test's own answers. The only mock is the
///      ecosystem's `ChainAssetHandler` (the shared CTM fixture's, which the pause window needs);
///      the sequence merely names it.
contract RegistryBootstrapSequenceTest is ChainTypeManagerTest {
    RegistryBootstrapMigration internal migration;
    RegistryBootstrapSequence internal sequence;
    CTMUpgradeExecutor internal ctmExecutor;
    CoreUpgradeExecutor internal coreExecutor;
    EcosystemUpgradeExecutor internal coordinator;
    CTMRelease internal genesisRelease;
    GovernanceUpgradeTimer internal upgradeTimer;
    ICoreTransition internal coreTransition;

    /// @dev Production shape: the CTM domain sits under its OWN admin, the ecosystem singletons
    ///      under the shared one. The edge hands each to a different executor.
    ProxyAdmin internal ctmProxyAdmin;
    ProxyAdmin internal ecosystemProxyAdmin;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    TransparentUpgradeableProxy internal bridgehubProxy;

    address internal implOld;
    address internal implNew;
    /// @dev The pre-bootstrap ServerNotifier: under its own ProxyAdmin, owned by the chain admin.
    address internal chainAdmin;
    ProxyAdmin internal notifierAdmin;
    TransparentUpgradeableProxy internal notifierProxy;
    address internal notifierImplOld;
    address internal notifierImplNew;
    address internal genesisUpgradeAddr;
    address internal upgradeEngine;
    address internal mockChainAssetHandler;
    uint256 internal newVersion;

    function setUp() public {
        deploy();
        // `setNewVersionUpgrade` requires migrations paused — the window stage 0 opens.
        _mockMigrationPausedFromBridgehub();
        mockChainAssetHandler = makeAddr("mockChainAssetHandler");

        implOld = address(new SeqImplOld());
        implNew = address(new SeqImplNew());

        ctmProxyAdmin = new ProxyAdmin();
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        ecosystemProxyAdmin = new ProxyAdmin();
        bridgehubProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");

        chainAdmin = makeAddr("chainAdmin");
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(chainAdmin);
        notifierImplOld = address(new ServerNotifier());
        notifierImplNew = address(new ServerNotifier());
        notifierProxy = new TransparentUpgradeableProxy(
            notifierImplOld,
            address(notifierAdmin),
            abi.encodeCall(ServerNotifier.initialize, (chainAdmin))
        );
        vm.prank(chainAdmin);
        ServerNotifier(address(notifierProxy)).setChainTypeManager(IChainTypeManager(address(chainContractAddress)));
        vm.prank(governor);
        chainContractAddress.setServerNotifier(address(notifierProxy));

        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");
        upgradeEngine = makeAddr("upgradeEngine");
        vm.etch(upgradeEngine, hex"600043");

        coreExecutor = new CoreUpgradeExecutor(governor, ecosystemProxyAdmin);
        coordinator = new EcosystemUpgradeExecutor(governor, coreExecutor);
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            address(coordinator)
        );

        // Governance holds both ProxyAdmins before the edge, as in production.
        ctmProxyAdmin.transferOwnership(governor);
        ecosystemProxyAdmin.transferOwnership(governor);

        newVersion = SemVer.packSemVer(0, 1, 0);
        // Started by the derived stage 0.
        upgradeTimer = new GovernanceUpgradeTimer(0, 0, governor, governor);

        _mockFacetSelfDescriptions(facetCuts);
        genesisRelease = _deployRelease();
        coreTransition = _deployCoreTransition();
        migration = new RegistryBootstrapMigration(_manifest());
        sequence = new RegistryBootstrapSequence(migration, coreTransition);
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _deployRelease() internal returns (CTMRelease) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({facet: facetCuts[i].facet, isFreezable: facetCuts[i].isFreezable});
        }
        return
            new CTMRelease(
                ReleaseManifest({
                    protocolVersion: newVersion,
                    diamondInit: diamondInit,
                    verifier: address(testnetVerifier),
                    genesisUpgrade: genesisUpgradeAddr,
                    genesisFacets: genesisFacets,
                    genesis: ReleaseGenesisData({
                        fixedForceDeploymentsData: L2PlanFixtures.emptyTableForceDeploymentsData(),
                        genesisBatchHash: bytes32(uint256(1)),
                        genesisIndexRepeatedStorageChanges: 54
                    }),
                    l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                    l2SystemProxyBytecodeInfo: L2PlanFixtures.bytecodeInfo(hex"dd00")
                })
            );
    }

    /// @dev One participating ecosystem row, so the core leg the derived stage 1 applies is a real
    ///      edge.
    function _deployCoreTransition() internal returns (ICoreTransition) {
        CoreTransitionManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(bridgehubProxy),
            expectedOldImpl: implOld,
            implNew: implNew,
            callInitializeUpgrade: false
        });
        return ICoreTransition(address(new CoreTransition(manifest)));
    }

    function _manifest() internal view returns (BootstrapManifest memory) {
        ProxyUpgradeRow[] memory upgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        upgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: address(ctmDomainProxy),
            expectedOldImpl: implOld,
            implNew: implNew,
            callInitializeUpgrade: false
        });
        upgrades[uint256(CTMContract.ServerNotifier)] = ProxyUpgradeRow({
            proxy: address(notifierProxy),
            expectedOldImpl: notifierImplOld,
            implNew: notifierImplNew,
            callInitializeUpgrade: false
        });
        return
            BootstrapManifest({
                ctm: address(chainContractAddress),
                expectedProtocolVersion: chainContractAddress.protocolVersion(),
                ctmProxyAdmin: ctmProxyAdmin,
                ctmProxyUpgrades: upgrades,
                currentRelease: address(genesisRelease),
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeEngine: upgradeEngine,
                l2Plan: L2PlanFixtures.emptyPlan(),
                upgradeTimestamp: 0,
                ctmExecutor: address(ctmExecutor),
                coreExecutor: address(coreExecutor),
                governance: governor,
                coordinator: address(coordinator),
                upgradeTimer: address(upgradeTimer)
            });
    }

    /// @dev The inputs both retired scripts authored their calls from.
    function _legacyInputs() internal view returns (LegacyBootstrapSequence.Inputs memory) {
        return
            LegacyBootstrapSequence.Inputs({
                chainAssetHandler: mockChainAssetHandler,
                upgradeTimer: address(upgradeTimer),
                ecosystemProxyAdmin: address(ecosystemProxyAdmin),
                coreUpgradeExecutor: address(coreExecutor),
                coreTransition: address(coreTransition),
                ctm: address(chainContractAddress),
                ctmProxyAdmin: address(ctmProxyAdmin),
                bootstrapMigration: address(migration),
                coordinator: address(coordinator),
                ctmUpgradeExecutor: address(ctmExecutor)
            });
    }

    function _calls(BootstrapAction[] memory _actions) internal pure returns (Call[] memory calls) {
        calls = new Call[](_actions.length);
        for (uint256 i = 0; i < _actions.length; ++i) {
            calls[i] = _actions[i].call;
        }
    }

    function _assertSameCall(Call memory _derived, Call memory _authored, string memory _what) internal {
        assertEq(_derived.target, _authored.target, string.concat(_what, ": target"));
        assertEq(_derived.value, _authored.value, string.concat(_what, ": value"));
        assertEq(_derived.data, _authored.data, string.concat(_what, ": calldata"));
    }

    /// @dev The ChainAdmin's half of the one-time notifier handover.
    function _chainAdminHandsOverTheNotifier() internal {
        vm.startPrank(chainAdmin);
        notifierAdmin.changeProxyAdmin(ITransparentUpgradeableProxy(address(notifierProxy)), address(ctmProxyAdmin));
        Ownable2Step(address(notifierProxy)).transferOwnership(address(ctmExecutor));
        vm.stopPrank();
    }

    /// @dev Executes the derived stage-0 accept as governance.
    function _runDerivedNotifierAccept() internal {
        Call memory accept = sequence.stage0Actions()[0].call;
        assertEq(accept.target, address(ctmExecutor), "the first stage-0 action is the executor's accept");
        vm.prank(governor);
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = accept.target.call{value: accept.value}(accept.data);
        assertTrue(ok, "the derived accept must succeed once the ChainAdmin nominated the executor");
    }

    /// @dev Executes one derived stage as governance, call by call. The fixture's chain asset
    ///      handler is a mock whose pause answer is fixed by the fixture, so its calls are skipped.
    /// @param _actions The derived stage.
    /// @param _skip A call index not to execute (`type(uint256).max` for none).
    function _runDerivedStage(BootstrapAction[] memory _actions, uint256 _skip) internal {
        for (uint256 i = 0; i < _actions.length; ++i) {
            Call memory call = _actions[i].call;
            if (call.target == mockChainAssetHandler || i == _skip) {
                continue;
            }
            vm.prank(governor);
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = call.target.call{value: call.value}(call.data);
            assertTrue(ok, string.concat(_actions[i].label, " reverted"));
        }
    }

    /// @dev The ChainAdmin's half of the notifier handover, then the derived stages 0 and 1.
    function _runEdgeThroughStage1() internal {
        _chainAdminHandsOverTheNotifier();
        _runDerivedStage(sequence.stage0Actions(), type(uint256).max);
        _runDerivedStage(sequence.stage1Actions(), type(uint256).max);
    }

    /// @dev Stage 2's unpause, as the fixture's mocked handler sees it.
    function _unpauseMigrations() internal {
        vm.mockCall(mockChainAssetHandler, abi.encodeWithSignature("migrationPausedFor(address)"), abi.encode(false));
    }

    // ──────────────────── the sequence is the one it replaced ────────────────────

    /// @notice Until the notifier handover is accepted, stage 0 differs from the authored bundle
    ///         in exactly one way: it starts with the executor's accept of the notifier. Once
    ///         accepted, it is the authored bundle again.
    function test_stage0_isTheAuthoredSequenceAfterTheNotifierAccept() public {
        Call[] memory derived = _calls(sequence.stage0Actions());
        Call[] memory authored = LegacyBootstrapSequence.stage0(_legacyInputs());
        assertEq(derived.length, authored.length + 1, "stage 0: the accept, then the authored calls");
        _assertSameCall(
            derived[0],
            Call({
                target: address(ctmExecutor),
                value: 0,
                data: abi.encodeCall(UpgradeExecutorBase.forward, (_singleAcceptCall()))
            }),
            "stage 0 accept"
        );
        for (uint256 i = 0; i < authored.length; ++i) {
            _assertSameCall(derived[i + 1], authored[i], string.concat("stage 0 call ", vm.toString(i + 1)));
        }

        _chainAdminHandsOverTheNotifier();
        _runDerivedNotifierAccept();
        assertEq(Ownable2Step(address(notifierProxy)).owner(), address(ctmExecutor), "the accept landed");
        assertEq(Ownable2Step(address(notifierProxy)).pendingOwner(), address(0));

        derived = _calls(sequence.stage0Actions());
        assertEq(derived.length, authored.length, "stage 0 length after the accept");
        for (uint256 i = 0; i < authored.length; ++i) {
            _assertSameCall(derived[i], authored[i], string.concat("stage 0 call ", vm.toString(i)));
        }
    }

    /// @notice The accept is governance's half only: before the ChainAdmin nominated the
    ///         executor, it reverts and with it the whole stage-0 bundle.
    function test_derivedNotifierAccept_revertsUntilTheChainAdminNominated() public {
        Call memory accept = sequence.stage0Actions()[0].call;
        vm.prank(governor);
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        UpgradeExecutorBase(payable(accept.target)).forward(_singleAcceptCall());
        assertEq(Ownable2Step(address(notifierProxy)).owner(), chainAdmin, "nothing moved");
    }

    /// @notice Stage 1 is the authored stage 1 with the two executor bindings the authored
    ///         stage 2 made moved in right after the pause, ahead of every handover: `migrate()`
    ///         (last) refuses unless they hold.
    function test_stage1_isTheAuthoredSequenceWithTheBindingsAhead() public {
        Call[] memory derived = _calls(sequence.stage1Actions());
        Call[] memory authored1 = LegacyBootstrapSequence.stage1(_legacyInputs());
        Call[] memory authored2 = LegacyBootstrapSequence.stage2(_legacyInputs());
        assertEq(derived.length, authored1.length + 2, "stage 1: the authored calls plus the two bindings");

        _assertSameCall(derived[0], authored1[0], "stage 1 pause");
        // authored2[1] is the core executor's `setCoordinator`, authored2[3] the coordinator's
        // `setCTMExecutor`.
        _assertSameCall(derived[1], authored2[1], "stage 1 core binding");
        _assertSameCall(derived[2], authored2[3], "stage 1 coordinator binding");
        for (uint256 i = 1; i < authored1.length; ++i) {
            _assertSameCall(derived[i + 2], authored1[i], string.concat("stage 1 call ", vm.toString(i + 2)));
        }
    }

    /// @notice Stage 2 is the authored unpause alone: no binding and no completion check rides it,
    ///         so a failing completion check cannot hold the unpause back.
    function test_stage2_isTheAuthoredUnpauseAlone() public {
        Call[] memory derived = _calls(sequence.stage2Actions());
        Call[] memory authored = LegacyBootstrapSequence.stage2(_legacyInputs());
        assertEq(derived.length, 1, "stage 2: the unpause only");
        // authored[2] is `unpauseMigration`.
        _assertSameCall(derived[0], authored[2], "stage 2 unpause");
    }

    /// @notice Every derived action carries the label and authority a reviewer reads it under, so
    ///         the prepare hands them straight to the external-actions ledger rather than pairing
    ///         them with the calls by position.
    function test_everyDerivedActionCarriesItsLabelAndAuthority() public {
        BootstrapAction[][] memory stages = new BootstrapAction[][](3);
        stages[0] = sequence.stage0Actions();
        stages[1] = sequence.stage1Actions();
        stages[2] = sequence.stage2Actions();
        for (uint256 stage = 0; stage < stages.length; ++stage) {
            for (uint256 i = 0; i < stages[stage].length; ++i) {
                assertGt(bytes(stages[stage][i].label).length, 0, "every action is labelled");
                assertGt(bytes(stages[stage][i].authority).length, 0, "every action names its authority");
                assertTrue(stages[stage][i].call.target != address(0), "every action has a target");
            }
        }
    }

    // ──────────────────── it refuses inputs the edge does not name ────────────────────

    /// @dev Retargeted from the removed codehash anchor: the registry is the one input the edge
    ///      does not name, so the sequence still refuses to pin an address that is not deployed —
    ///      stage 1 would otherwise "apply" it against nothing.
    function test_revertWhen_theCoreTransitionIsNotDeployed() public {
        address codeless = makeAddr("codelessCoreTransition");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        new RegistryBootstrapSequence(migration, ICoreTransition(codeless));
    }

    function test_revertWhen_anInputIsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapSequence(migration, ICoreTransition(address(0)));

        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapSequence(RegistryBootstrapMigration(address(0)), coreTransition);
    }

    function test_revertWhen_theMigrationIsNotDeployed() public {
        address codeless = makeAddr("codelessMigration");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        new RegistryBootstrapSequence(RegistryBootstrapMigration(codeless), coreTransition);
    }

    // ──────────────────── the derived stages run the edge ────────────────────

    /// @notice The derived stages, executed in order, perform the whole edge; the completion
    ///         check then passes as its own call once stage 2 lifted the pause.
    function test_derivedStagesRunTheEdge_thenTheCompletionCheckPasses() public {
        vm.expectRevert(BootstrapNotYetExecuted.selector);
        sequence.validateApplied();

        _runEdgeThroughStage1();

        assertTrue(migration.executed(), "the edge is spent");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the CTM sits at the new version");
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(bridgehubProxy))),
            implNew,
            "the ecosystem row is applied"
        );
        assertEq(ecosystemProxyAdmin.owner(), address(coreExecutor), "the ecosystem admin is the core executor's");
        assertEq(coreExecutor.coordinator(), address(coordinator), "the core executor is bound");
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor), "the coordinator is bound");
        assertEq(chainContractAddress.owner(), address(ctmExecutor), "the CTM is the executor's");

        // Before stage 2 lifts the pause, completion is not reached.
        vm.expectRevert(MigrationPaused.selector);
        sequence.validateApplied();

        _runDerivedStage(sequence.stage2Actions(), type(uint256).max);
        _unpauseMigrations();
        sequence.validateApplied();
    }

    /// @notice A completion check that fails cannot hold anything back: the bindings were made
    ///         in stage 1 and stage 2 still runs; the check passes once the cause is removed.
    function test_aFailingCompletionCheckDoesNotHoldBackStage2() public {
        _runEdgeThroughStage1();
        address attacker = makeAddr("attacker");
        vm.prank(governor);
        coordinator.transferOwnership(attacker);

        _runDerivedStage(sequence.stage2Actions(), type(uint256).max);
        _unpauseMigrations();
        vm.expectRevert(abi.encodeWithSelector(BootstrapNominationPending.selector, address(coordinator), attacker));
        sequence.validateApplied();

        vm.prank(governor);
        coordinator.transferOwnership(address(0));
        sequence.validateApplied();
    }

    /// @notice Stage 1's `migrate()` refuses unless the ecosystem `ProxyAdmin` reached the core
    ///         executor earlier in the same stage, so a stage 1 missing that handover reverts as a
    ///         whole.
    function test_migrateRefusesWithoutTheEcosystemHandover() public {
        _chainAdminHandsOverTheNotifier();
        _runDerivedStage(sequence.stage0Actions(), type(uint256).max);
        BootstrapAction[] memory stage1 = sequence.stage1Actions();
        // Everything but the migrate (last) and the ecosystem ProxyAdmin handover (index 3) and
        // the core leg that needs it (index 4).
        for (uint256 i = 0; i < stage1.length - 1; ++i) {
            Call memory call = stage1[i].call;
            if (call.target == mockChainAssetHandler || i == 3 || i == 4) {
                continue;
            }
            vm.prank(governor);
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = call.target.call{value: call.value}(call.data);
            assertTrue(ok, string.concat(stage1[i].label, " reverted"));
        }

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, address(ecosystemProxyAdmin), governor)
        );
        migration.migrate();
        assertFalse(migration.executed(), "a refused edge must stay unspent");
    }

    /// @notice The completion check does not re-read the ecosystem rows: a re-patch governance
    ///         made after the core leg leaves completion possible.
    function test_validateApplied_passesAfterAnEcosystemRepatch() public {
        _runEdgeThroughStage1();
        _runDerivedStage(sequence.stage2Actions(), type(uint256).max);
        _unpauseMigrations();

        Call[] memory repatch = new Call[](1);
        repatch[0] = Call({
            target: address(ecosystemProxyAdmin),
            value: 0,
            data: abi.encodeCall(ProxyAdmin.upgrade, (ITransparentUpgradeableProxy(address(bridgehubProxy)), implOld))
        });
        vm.prank(governor);
        coreExecutor.forward(repatch);
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(bridgehubProxy))),
            implOld,
            "fixture: the ecosystem proxy moved off the row's target"
        );

        sequence.validateApplied();
    }

    function _singleAcceptCall() internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: address(notifierProxy),
            value: 0,
            data: abi.encodeCall(Ownable2Step.acceptOwnership, ())
        });
    }
}

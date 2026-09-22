// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Call} from "contracts/governance/Common.sol";
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
import {
    BootstrapAction,
    IRegistryBootstrapSequence
} from "contracts/upgrades/registry/bootstrap/IRegistryBootstrapSequence.sol";
import {
    BootstrapNotYetExecuted,
    ProxyUpgradeRowMismatch,
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
///         edge already deploys, and that the derivation is the same sequence the two v34 prepare
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

        newVersion = SemVer.packSemVer(0, 1, 0);
        upgradeTimer = new GovernanceUpgradeTimer(0, 0, governor, governor);
        vm.prank(governor);
        upgradeTimer.startTimer();

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
                        fixedForceDeploymentsData: hex"f1f2",
                        genesisBatchHash: bytes32(uint256(1)),
                        genesisIndexRepeatedStorageChanges: 54
                    }),
                    l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                    l2SystemProxyBytecodeInfo: L2PlanFixtures.bytecodeInfo(hex"dd00")
                })
            );
    }

    /// @dev One participating ecosystem row, so the core leg is a real edge the completion gate
    ///      can find unapplied.
    function _deployCoreTransition() internal returns (ICoreTransition) {
        CoreTransitionManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(bridgehubProxy),
            expectedOldImpl: implOld,
            implNew: implNew,
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        return ICoreTransition(address(new CoreTransition(manifest)));
    }

    function _manifest() internal view returns (BootstrapManifest memory) {
        ProxyUpgradeRow[] memory upgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        upgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: address(ctmDomainProxy),
            expectedOldImpl: implOld,
            implNew: implNew,
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        return
            BootstrapManifest({
                ctm: address(chainContractAddress),
                expectedProtocolVersion: chainContractAddress.protocolVersion(),
                ctmProxyAdmin: ctmProxyAdmin,
                proxyUpgrades: upgrades,
                currentRelease: address(genesisRelease),
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeEngine: upgradeEngine,
                l2Plan: L2PlanFixtures.emptyPlan(),
                upgradeTimestamp: 0,
                ctmExecutor: address(ctmExecutor),
                ctmExecutorOwner: governor,
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

    /// @dev Runs the edge's CTM leg: governance hands both CTM-domain authorities over and the
    ///      permissionless `migrate()` performs the whole edge.
    function _runCtmLeg() internal {
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(migration));
        ctmProxyAdmin.transferOwnership(address(migration));
        migration.migrate();
    }

    /// @dev Runs the edge's ecosystem leg: governance hands the shared admin to the bound executor
    ///      and applies the pinned inventory through it.
    function _runCoreLeg() internal {
        ecosystemProxyAdmin.transferOwnership(address(coreExecutor));
        vm.prank(governor);
        coreExecutor.applyL1Upgrade(coreTransition);
    }

    /// @dev Stage 2's unpause, as the fixture's mocked handler sees it.
    function _unpauseMigrations() internal {
        vm.mockCall(mockChainAssetHandler, abi.encodeWithSignature("migrationPausedFor(address)"), abi.encode(false));
    }

    // ──────────────────── the sequence is the one it replaced ────────────────────

    function test_stage0_matchesTheAuthoredSequence() public {
        Call[] memory derived = _calls(sequence.stage0Actions());
        Call[] memory authored = LegacyBootstrapSequence.stage0(_legacyInputs());
        assertEq(derived.length, authored.length, "stage 0 length");
        for (uint256 i = 0; i < authored.length; ++i) {
            _assertSameCall(derived[i], authored[i], string.concat("stage 0 call ", vm.toString(i)));
        }
    }

    function test_stage1_matchesTheAuthoredSequence() public {
        Call[] memory derived = _calls(sequence.stage1Actions());
        Call[] memory authored = LegacyBootstrapSequence.stage1(_legacyInputs());
        assertEq(derived.length, authored.length, "stage 1 length");
        for (uint256 i = 0; i < authored.length; ++i) {
            _assertSameCall(derived[i], authored[i], string.concat("stage 1 call ", vm.toString(i)));
        }
    }

    /// @notice Stage 2 differs from the authored bundle in exactly one way, by design: the two
    ///         separate post-state checks (the core executor's applied-row check, authored FIRST,
    ///         and the migration's `validateApplied()`, authored LAST) are folded into the single
    ///         completion gate that terminates every derived stage 2. The three calls that do
    ///         work are byte-identical and keep their relative order.
    function test_stage2_matchesTheAuthoredSequenceWithTheChecksFolded() public {
        Call[] memory derived = _calls(sequence.stage2Actions());
        Call[] memory authored = LegacyBootstrapSequence.stage2(_legacyInputs());
        assertEq(derived.length, 4, "stage 2: three working calls plus the completion gate");
        assertEq(authored.length, 5, "the authored stage 2 carried two separate checks");

        // authored[1..3] are `setCoordinator`, `unpauseMigration`, `setCTMExecutor`.
        for (uint256 i = 0; i < 3; ++i) {
            _assertSameCall(derived[i], authored[i + 1], string.concat("stage 2 call ", vm.toString(i)));
        }
    }

    function test_stage2_endsWithTheCompletionGate() public {
        BootstrapAction[] memory actions = sequence.stage2Actions();
        Call memory terminal = actions[actions.length - 1].call;
        assertEq(terminal.target, address(sequence), "the gate is the sequence's own check");
        assertEq(terminal.value, 0, "the gate carries no value");
        assertEq(
            terminal.data,
            abi.encodeCall(IRegistryBootstrapSequence.validateApplied, ()),
            "the gate is `validateApplied()`"
        );
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

    // ──────────────────── the completion gate requires BOTH domains ────────────────────

    function test_validateApplied_revertsBeforeTheEdgeRuns() public {
        // The ecosystem rows are unapplied, so the core half fails first.
        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(bridgehubProxy), implNew, implOld)
        );
        sequence.validateApplied();
    }

    /// @notice The ecosystem leg alone is not completion: the gate still refuses while the CTM
    ///         edge is unspent. This is the half the authored bundle could drop by omitting one
    ///         of its two check calls.
    function test_validateApplied_revertsWhenOnlyTheEcosystemLegRan() public {
        _runCoreLeg();
        vm.expectRevert(BootstrapNotYetExecuted.selector);
        sequence.validateApplied();
    }

    /// @notice And the CTM edge alone is not completion either.
    function test_validateApplied_revertsWhenOnlyTheCtmLegRan() public {
        _runCtmLeg();
        _unpauseMigrations();
        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(bridgehubProxy), implNew, implOld)
        );
        sequence.validateApplied();
    }

    function test_validateApplied_passesOnceBothDomainsApplied() public {
        _runCoreLeg();
        _runCtmLeg();
        // The stage-2 binding the migration's own gate requires, and the unpause both gates do.
        vm.prank(governor);
        coordinator.setCTMExecutor(ctmExecutor);
        _unpauseMigrations();

        sequence.validateApplied();

        // The gate is a real post-state read, not a tautology: both domains actually moved.
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(bridgehubProxy))),
            implNew,
            "the ecosystem row must be applied"
        );
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the CTM must sit at the new version");
        assertTrue(migration.executed(), "the edge must be spent");
    }

    /// @notice Executing the derived stage-2 bundle in order leaves the gate satisfied — the
    ///         unpause the gate depends on is ordered ahead of it by the derivation itself.
    function test_derivedStage2_leavesTheCompletionGateSatisfied() public {
        _runCoreLeg();
        _runCtmLeg();

        Call[] memory stage2 = _calls(sequence.stage2Actions());
        for (uint256 i = 0; i < stage2.length; ++i) {
            if (stage2[i].target == mockChainAssetHandler) {
                // The fixture's handler is a mock, so the unpause is applied as the mock's answer.
                _unpauseMigrations();
                continue;
            }
            vm.prank(governor);
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, ) = stage2[i].target.call{value: stage2[i].value}(stage2[i].data);
            assertTrue(ok, string.concat("stage 2 call ", vm.toString(i), " reverted"));
        }

        assertEq(coreExecutor.coordinator(), address(coordinator), "the core executor must be bound");
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor), "the coordinator must be bound");
    }
}

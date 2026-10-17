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
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {RegistryBootstrapSequence} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapSequence.sol";
import {BootstrapAction} from "contracts/upgrades/registry/bootstrap/IRegistryBootstrapSequence.sol";
import {
    BootstrapAuthorityNotHeld,
    BootstrapNominationPending,
    BootstrapNotYetExecuted,
    ProxyUpgradeDomainMismatch,
    RegistryTargetHasNoCode,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {
    BootstrapManifest,
    GenesisFacet,
    ProxyUpgradeDomain,
    ProxyUpgradeRow,
    ProxyUpgradeTransitionManifest,
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

/// @notice Tests that the bootstrap edge's one governance bundle is DERIVED from the objects the
///         edge already deploys, call for call, and that executing it as one bundle performs the
///         whole edge and ends in the passing completion check — or reverts as a whole.
/// @dev Driven against real objects throughout — a real `ChainTypeManager`, real OpenZeppelin
///      `ProxyAdmin`s for both domains, a real Core-domain `ProxyUpgradeTransition` and a real
///      `RegistryBootstrapMigration` — because the property under test is the derivation, and a
///      mocked object would be deriving from the test's own answers.
contract RegistryBootstrapSequenceTest is ChainTypeManagerTest {
    RegistryBootstrapMigration internal migration;
    RegistryBootstrapSequence internal sequence;
    CTMUpgradeExecutor internal ctmExecutor;
    CoreUpgradeExecutor internal coreExecutor;
    CTMRelease internal genesisRelease;
    IProxyUpgradeTransition internal coreTransition;

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
    uint256 internal newVersion;

    function setUp() public {
        deploy();

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
        ctmExecutor = new CTMUpgradeExecutor(governor, IChainTypeManager(address(chainContractAddress)), ctmProxyAdmin);

        // Governance holds both ProxyAdmins before the edge, as in production.
        ctmProxyAdmin.transferOwnership(governor);
        ecosystemProxyAdmin.transferOwnership(governor);

        newVersion = SemVer.packSemVer(0, 1, 0);

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

    /// @dev One participating ecosystem row, so the core leg the derived bundle applies is a real
    ///      edge.
    function _deployCoreTransition() internal returns (IProxyUpgradeTransition) {
        ProxyUpgradeTransitionManifest memory manifest;
        manifest.domain = ProxyUpgradeDomain.Core;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(bridgehubProxy),
            expectedOldImpl: implOld,
            implNew: implNew,
            callInitializeUpgrade: false
        });
        return new ProxyUpgradeTransition(manifest);
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
                governance: governor
            });
    }

    function _calls(BootstrapAction[] memory _actions) internal pure returns (Call[] memory calls) {
        calls = new Call[](_actions.length);
        for (uint256 i = 0; i < _actions.length; ++i) {
            calls[i] = _actions[i].call;
        }
    }

    function _assertSameCall(Call memory _derived, Call memory _authored, string memory _what) internal pure {
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

    /// @dev Executes `_calls` as governance, in order, ALL OR NOTHING — the way a governance bundle
    ///      runs. Called through `this` so a failing call reverts every call before it.
    function runBundle(Call[] memory _bundle) external {
        require(msg.sender == address(this), "test-internal");
        for (uint256 i = 0; i < _bundle.length; ++i) {
            vm.prank(governor);
            // solhint-disable-next-line avoid-low-level-calls
            (bool ok, bytes memory returnData) = _bundle[i].target.call{value: _bundle[i].value}(_bundle[i].data);
            if (!ok) {
                assembly {
                    revert(add(returnData, 0x20), mload(returnData))
                }
            }
        }
    }

    /// @dev The bundle the sequence derives, without the notifier accept once it is no longer due:
    ///      every call but the accept, in order, as this suite expects them.
    function _expectedBundleAfterTheAccept() internal view returns (Call[] memory calls) {
        calls = new Call[](6);
        calls[0] = Call({
            target: address(ecosystemProxyAdmin),
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (address(coreExecutor)))
        });
        calls[1] = Call({
            target: address(coreExecutor),
            value: 0,
            data: abi.encodeCall(CoreUpgradeExecutor.applyL1Upgrade, (coreTransition))
        });
        calls[2] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (address(migration)))
        });
        calls[3] = Call({
            target: address(ctmProxyAdmin),
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (address(migration)))
        });
        calls[4] = Call({
            target: address(migration),
            value: 0,
            data: abi.encodeCall(RegistryBootstrapMigration.migrate, ())
        });
        calls[5] = Call({
            target: address(migration),
            value: 0,
            data: abi.encodeCall(RegistryBootstrapMigration.validateApplied, ())
        });
    }

    function _assertBundle(Call[] memory _derived, Call[] memory _expected) internal pure {
        assertEq(_derived.length, _expected.length, "bundle length");
        for (uint256 i = 0; i < _expected.length; ++i) {
            _assertSameCall(_derived[i], _expected[i], string.concat("bundle call ", vm.toString(i)));
        }
    }

    /// @dev Nothing of the edge stands: the state before the bundle.
    function _assertEdgeNotApplied() internal view {
        assertFalse(migration.executed(), "the edge must stay unspent");
        assertEq(chainContractAddress.owner(), governor, "governance keeps the CTM");
        assertEq(ctmProxyAdmin.owner(), governor, "and the CTM-domain ProxyAdmin");
        assertEq(ecosystemProxyAdmin.owner(), governor, "and the ecosystem ProxyAdmin");
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(bridgehubProxy))),
            implOld,
            "the ecosystem row is not applied"
        );
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version does not move");
    }

    // ──────────────────── the bundle is derived ────────────────────

    /// @notice While the notifier handover is unaccepted, the bundle opens with the executor's
    ///         accept; once accepted, the bundle is the rest alone. It contains no pause, unpause or
    ///         timer call, and it closes with the completion check.
    function test_actions_areTheWholeBundleInOrder() public {
        Call[] memory derived = _calls(sequence.actions());
        Call[] memory rest = _expectedBundleAfterTheAccept();
        assertEq(derived.length, rest.length + 1, "the accept, then the rest");
        _assertSameCall(
            derived[0],
            Call({
                target: address(ctmExecutor),
                value: 0,
                data: abi.encodeCall(UpgradeExecutorBase.forward, (_singleAcceptCall()))
            }),
            "the notifier accept"
        );
        for (uint256 i = 0; i < rest.length; ++i) {
            _assertSameCall(derived[i + 1], rest[i], string.concat("bundle call ", vm.toString(i + 1)));
        }

        _chainAdminHandsOverTheNotifier();
        Call[] memory accept = new Call[](1);
        accept[0] = derived[0];
        this.runBundle(accept);
        assertEq(Ownable2Step(address(notifierProxy)).owner(), address(ctmExecutor), "the accept landed");
        assertEq(Ownable2Step(address(notifierProxy)).pendingOwner(), address(0));

        _assertBundle(_calls(sequence.actions()), rest);
    }

    /// @notice The accept is governance's half only: before the ChainAdmin nominated the
    ///         executor, it reverts and with it the whole bundle.
    function test_derivedNotifierAccept_revertsUntilTheChainAdminNominated() public {
        Call[] memory bundle = _calls(sequence.actions());
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        this.runBundle(bundle);
        assertEq(Ownable2Step(address(notifierProxy)).owner(), chainAdmin, "nothing moved");
        _assertEdgeNotApplied();
    }

    /// @notice Every derived action carries the label and authority a reviewer reads it under, so
    ///         the prepare hands them straight to the external-actions ledger rather than pairing
    ///         them with the calls by position.
    function test_everyDerivedActionCarriesItsLabelAndAuthority() public view {
        BootstrapAction[] memory actions = sequence.actions();
        for (uint256 i = 0; i < actions.length; ++i) {
            assertGt(bytes(actions[i].label).length, 0, "every action is labelled");
            assertGt(bytes(actions[i].authority).length, 0, "every action names its authority");
            assertTrue(actions[i].call.target != address(0), "every action has a target");
        }
    }

    // ──────────────────── it refuses inputs the edge does not name ────────────────────

    /// @dev The core transition is the one input the edge does not name, so the sequence refuses
    ///      to pin an address that is not deployed — the bundle would otherwise "apply" it against
    ///      nothing.
    function test_revertWhen_theCoreTransitionIsNotDeployed() public {
        address codeless = makeAddr("codelessCoreTransition");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        new RegistryBootstrapSequence(migration, IProxyUpgradeTransition(codeless));
    }

    /// @dev The sequence's core leg runs through the core executor, so a CTM-domain object is
    ///      refused when the sequence is built rather than when governance executes it.
    function test_revertWhen_theCoreTransitionIsACTMDomainObject() public {
        ProxyUpgradeTransitionManifest memory manifest;
        manifest.domain = ProxyUpgradeDomain.CTM;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = ProxyUpgradeRow({
            proxy: address(ctmDomainProxy),
            expectedOldImpl: implOld,
            implNew: implNew,
            callInitializeUpgrade: false
        });
        ProxyUpgradeTransition ctmDomain = new ProxyUpgradeTransition(manifest);
        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeDomainMismatch.selector,
                uint8(ProxyUpgradeDomain.Core),
                uint8(ProxyUpgradeDomain.CTM)
            )
        );
        new RegistryBootstrapSequence(migration, ctmDomain);
    }

    function test_revertWhen_anInputIsZero() public {
        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapSequence(migration, IProxyUpgradeTransition(address(0)));

        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapSequence(RegistryBootstrapMigration(address(0)), coreTransition);
    }

    function test_revertWhen_theMigrationIsNotDeployed() public {
        address codeless = makeAddr("codelessMigration");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        new RegistryBootstrapSequence(RegistryBootstrapMigration(codeless), coreTransition);
    }

    // ──────────────────── the bundle runs the edge ────────────────────

    /// @notice The derived bundle, executed as one, performs the whole edge and ends in the passing
    ///         completion check.
    function test_theBundleRunsTheEdgeAndEndsInThePassingCompletionCheck() public {
        vm.expectRevert(BootstrapNotYetExecuted.selector);
        migration.validateApplied();

        _chainAdminHandsOverTheNotifier();
        this.runBundle(_calls(sequence.actions()));

        assertTrue(migration.executed(), "the edge is spent");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the CTM sits at the new version");
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(bridgehubProxy))),
            implNew,
            "the ecosystem row is applied"
        );
        assertEq(ecosystemProxyAdmin.owner(), address(coreExecutor), "the ecosystem admin is the core executor's");
        assertEq(chainContractAddress.owner(), address(ctmExecutor), "the CTM is the executor's");
        assertEq(ctmProxyAdmin.owner(), address(ctmExecutor), "and so is its ProxyAdmin");
        assertEq(Ownable2Step(address(notifierProxy)).owner(), address(ctmExecutor), "and the notifier");
        migration.validateApplied();
    }

    /// @notice The completion check is inside the bundle, so a failing check reverts the whole edge:
    ///         nothing the bundle did before it stands. A completed `migrate()` cannot by itself leave
    ///         the shape the check reads behind, so the failure is isolated with a mock of the one
    ///         read only the completion check makes: the CTM's version as seen from outside.
    function test_aFailingCompletionCheckRevertsTheWholeBootstrap() public {
        _chainAdminHandsOverTheNotifier();
        uint256 departing = chainContractAddress.protocolVersion();
        vm.mockCall(
            address(chainContractAddress),
            abi.encodeCall(IChainTypeManager.protocolVersion, ()),
            abi.encode(departing)
        );
        Call[] memory bundle = _calls(sequence.actions());

        vm.expectRevert(abi.encodeWithSelector(OutdatedProtocolVersion.selector, departing, newVersion));
        this.runBundle(bundle);

        vm.clearMockedCalls();
        _assertEdgeNotApplied();
        assertEq(
            Ownable2Step(address(notifierProxy)).owner(),
            chainAdmin,
            "the bundle's notifier accept is rolled back too"
        );
    }

    /// @notice `migrate()` refuses unless the ecosystem `ProxyAdmin` reached the core executor
    ///         earlier in the same bundle, so a bundle missing that handover reverts as a whole.
    function test_migrateRefusesWithoutTheEcosystemHandover() public {
        _chainAdminHandsOverTheNotifier();
        Call[] memory derived = _calls(sequence.actions());
        // The derived bundle minus the ecosystem ProxyAdmin handover (index 1, after the accept)
        // and the core leg that needs it (index 2).
        Call[] memory bundle = new Call[](derived.length - 2);
        uint256 next = 0;
        for (uint256 i = 0; i < derived.length; ++i) {
            if (i == 1 || i == 2) {
                continue;
            }
            bundle[next] = derived[i];
            ++next;
        }

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, address(ecosystemProxyAdmin), governor)
        );
        this.runBundle(bundle);
        _assertEdgeNotApplied();
    }

    /// @notice A nomination left on an executor the edge hands a domain to is refused by `migrate()`
    ///         itself (the completion check would refuse it too): the bundle reverts as a whole.
    function test_aPendingExecutorNominationRevertsTheWholeBootstrap() public {
        _chainAdminHandsOverTheNotifier();
        address attacker = makeAddr("attacker");
        vm.prank(governor);
        coreExecutor.transferOwnership(attacker);

        Call[] memory bundle = _calls(sequence.actions());
        vm.expectRevert(abi.encodeWithSelector(BootstrapNominationPending.selector, address(coreExecutor), attacker));
        this.runBundle(bundle);
        _assertEdgeNotApplied();
    }

    /// @notice The completion check does not re-read the ecosystem rows: a re-patch governance
    ///         made after the edge leaves it passing.
    function test_validateApplied_passesAfterAnEcosystemRepatch() public {
        _chainAdminHandsOverTheNotifier();
        this.runBundle(_calls(sequence.actions()));

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

        migration.validateApplied();
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

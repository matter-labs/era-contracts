// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {Utils} from "../../Utils/Utils.sol";
import {Vm} from "forge-std/Vm.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    BootstrapAlreadyExecuted,
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    BootstrapNotYetExecuted,
    DeadlineNotYetPassed,
    L2BytecodeNotPublished,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch,
    RegistryDuplicateProxyRow,
    TimerNotStarted,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    BootstrapManifest,
    ProxyUpgradeRow,
    GenesisFacet,
    ReleaseGenesisData,
    ReleaseManifest,
    PinnedContract
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "../../../../../../../contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @dev Two distinct implementations so a proxy row is a real `expectedOldImpl -> implNew` edge.
contract ImplV31 {
    function version() external pure returns (uint256) {
        return 31;
    }
}

contract ImplV32 {
    function version() external pure returns (uint256) {
        return 32;
    }
}

/// @dev An implementation no row knows: neither a source nor a target of the edge under test.
contract ImplUnknown {
    function version() external pure returns (uint256) {
        return 99;
    }
}

/// @notice Tests the single source-checked edge from a pre-registry ecosystem into the
///         registry-driven model: implementation swaps, provenance anchor + genesis release,
///         version edge, and the authority handover to the bound executors.
/// @dev Driven against a REAL `ZKsyncOSChainTypeManager` and a real OpenZeppelin `ProxyAdmin` — the two
///      contracts whose ownership the migration actually needs — rather than mocks, because the
///      property under test IS the authority movement.
contract RegistryBootstrapMigrationTest is ChainTypeManagerTest {
    RegistryBootstrapMigration internal migration;
    CTMUpgradeExecutor internal ctmExecutor;
    EcosystemUpgradeExecutor internal ecoExecutor;
    ProxyAdmin internal ecosystemProxyAdmin;

    CTMRelease internal genesisRelease;
    GovernanceUpgradeTimer internal upgradeTimer;
    TransparentUpgradeableProxy internal ecosystemProxy;
    address internal implV31;
    address internal implV32;
    address internal implUnknown;
    // The ServerNotifier shape: a per-CTM proxy under its OWN admin, owned by the chain admin
    // rather than by the CTM domain's ProxyAdmin ({docs/upgrade-stage-lifecycle.md}, section 4.4).
    address internal chainAdmin;
    ProxyAdmin internal notifierAdmin;
    TransparentUpgradeableProxy internal notifierProxy;
    address internal genesisUpgradeAddr;
    address internal upgradeCutInit;

    uint256 internal newVersion;

    function setUp() public {
        deploy();
        // `setNewVersionUpgrade` requires migrations paused — the window stage 0 opens and stage 2
        // closes. The bootstrap edge replaces stage 1, so it runs inside that same window.
        _mockMigrationPausedFromBridgehub();

        implV31 = address(new ImplV31());
        implV32 = address(new ImplV32());
        implUnknown = address(new ImplUnknown());
        ecosystemProxyAdmin = new ProxyAdmin();
        ecosystemProxy = new TransparentUpgradeableProxy(implV31, address(ecosystemProxyAdmin), hex"");
        chainAdmin = makeAddr("chainAdmin");
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(chainAdmin);
        notifierProxy = new TransparentUpgradeableProxy(implV31, address(notifierAdmin), hex"");

        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");
        upgradeCutInit = makeAddr("upgradeCutInit");
        vm.etch(upgradeCutInit, hex"600043");

        // The ecosystem executor is bound first: the CTM executor pins it as an immutable.
        ecoExecutor = new EcosystemUpgradeExecutor(governor, ecosystemProxyAdmin, Utils.coreRegistryCodehash());
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ecosystemProxyAdmin,
            ecoExecutor,
            Utils.transitionCodehash()
        );

        newVersion = SemVer.packSemVer(0, 1, 0);
        // The pinned timer gates `migrate()`: stage 0 starts it, the edge runs after its window.
        // Zero delays make the window pass immediately in the fixture.
        upgradeTimer = new GovernanceUpgradeTimer(0, 0, governor, governor);
        vm.prank(governor);
        upgradeTimer.startTimer();
        // The release constructor reads each facet's self-description (see the shared fixture).
        _mockFacetSelfDescriptions(facetCuts);
        genesisRelease = _deployGenesisRelease();
        migration = new RegistryBootstrapMigration(_manifest());
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _deployGenesisRelease() internal returns (CTMRelease result) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({
                facet: PinnedContract({addr: facetCuts[i].facet, codehash: facetCuts[i].facet.codehash}),
                isFreezable: facetCuts[i].isFreezable
            });
        }
        result = new CTMRelease(
            ReleaseManifest({
                diamondInit: PinnedContract({addr: diamondInit, codehash: diamondInit.codehash}),
                verifier: PinnedContract({addr: address(testnetVerifier), codehash: address(testnetVerifier).codehash}),
                genesisUpgrade: PinnedContract({addr: genesisUpgradeAddr, codehash: genesisUpgradeAddr.codehash}),
                genesisFacets: genesisFacets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(uint256(1)),
                    // ZKsyncOSChainTypeManager requires the commitment to be exactly 1.
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                // Length-checked inventory; content is irrelevant to this fixture.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
            })
        );
    }

    function _manifest() internal view returns (BootstrapManifest memory) {
        return _manifestWithFactoryDeps(new uint256[](0));
    }

    /// @dev The committed cut carries the engine's `upgrade(ProposedUpgrade)` calldata — the
    ///      migration decodes it to check the L2 transaction's factory dependencies are published.
    ///      The fixture never executes it (the CTM only commits its hash), so an otherwise-empty
    ///      proposal carrying `_factoryDeps` is the whole payload.
    function _upgradeCut(uint256[] memory _factoryDeps) internal view returns (Diamond.DiamondCutData memory) {
        ProposedUpgrade memory proposedUpgrade = ProposedUpgradeLib.emptyProposedUpgrade(newVersion);
        proposedUpgrade.l2ProtocolUpgradeTx.factoryDeps = _factoryDeps;
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: upgradeCutInit,
                initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
            });
    }

    function _manifestWithFactoryDeps(uint256[] memory _factoryDeps) internal view returns (BootstrapManifest memory) {
        // The one participating slot in the enum-indexed CTM-domain inventory: the CTM's own
        // implementation swap. The remaining slots stay inert (explicitly not upgraded).
        ProxyUpgradeRow[] memory upgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        upgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implV31,
            implNew: PinnedContract({addr: implV32, codehash: implV32.codehash}),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        return
            BootstrapManifest({
                ctm: address(chainContractAddress),
                expectedProtocolVersion: chainContractAddress.protocolVersion(),
                ctmProxyAdmin: ecosystemProxyAdmin,
                proxyUpgrades: upgrades,
                currentRelease: PinnedContract({addr: address(genesisRelease), codehash: Utils.releaseCodehash()}),
                newProtocolVersion: newVersion,
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeCut: _upgradeCut(_factoryDeps),
                upgradeCutInitCodehash: upgradeCutInit.codehash,
                ctmExecutor: PinnedContract({addr: address(ctmExecutor), codehash: address(ctmExecutor).codehash}),
                upgradeTimer: PinnedContract({addr: address(upgradeTimer), codehash: address(upgradeTimer).codehash})
            });
    }

    /// @dev The governance bundle this object replaces stage 1 with: nominate the CTM, hand over
    ///      the ProxyAdmin, migrate. Three calls instead of ~15.
    function _handOverAuthority() internal {
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(migration));
        ecosystemProxyAdmin.transferOwnership(address(migration));
    }

    /// @dev `_manifest()` plus the notifier row: the same edge, under the admin that actually
    ///      administers the notifier proxy — which the migration does not own.
    function _manifestWithNotifierRow() internal view returns (BootstrapManifest memory manifest) {
        manifest = _manifest();
        manifest.proxyUpgrades[uint256(CTMContract.ServerNotifier)] = ProxyUpgradeRow({
            proxy: address(notifierProxy),
            expectedOldImpl: implV31,
            implNew: PinnedContract({addr: implV32, codehash: implV32.codehash}),
            callInitializeUpgrade: false,
            admin: notifierAdmin
        });
    }

    /// @dev Deploys a migration for `_bootstrapManifest` and hands it the authority `_handOverAuthority`
    ///      hands the fixture's.
    function _deployAndAuthorize(
        BootstrapManifest memory _bootstrapManifest
    ) internal returns (RegistryBootstrapMigration deployed) {
        deployed = new RegistryBootstrapMigration(_bootstrapManifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(deployed));
        ecosystemProxyAdmin.transferOwnership(address(deployed));
    }

    function _liveImpl(ProxyAdmin _admin, TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return _admin.getProxyImplementation(ITransparentUpgradeableProxy(address(_proxy)));
    }

    /// @dev `validate()` is a view over live authority, and the CTM's two-step accept normally
    ///      happens inside `migrate()`. Completing it here (as the nominated migration) lets a test
    ///      read the source check on its own before spending the edge; `migrate()` then finds no
    ///      pending nomination and proceeds unchanged.
    function _completeCtmHandover(RegistryBootstrapMigration _migration) internal {
        vm.prank(address(_migration));
        chainContractAddress.acceptOwnership();
        assertEq(chainContractAddress.owner(), address(_migration));
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

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_migrate_performsTheWholeEdgeAndHandsOverAuthority() public {
        _handOverAuthority();
        uint256 oldVersion = chainContractAddress.protocolVersion();

        vm.recordLogs();
        migration.migrate();
        _assertBootstrappedEventEmitted();

        // The object's own post-state check covers the whole edge (version, release pin, rows,
        // authority landing); the granular asserts below then pin the exact expected values.
        migration.validateApplied();

        // The ecosystem proxy moved to its pinned implementation.
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implV32,
            "proxy must point at the pinned implementation"
        );
        // The registry anchors are installed and the version edge committed.
        assertEq(chainContractAddress.releaseCodehash(), Utils.releaseCodehash(), "anchor must be installed");
        assertEq(chainContractAddress.currentRelease(), address(genesisRelease), "release must be pinned");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "version must be bumped");
        assertTrue(chainContractAddress.upgradeCutHash(oldVersion) != bytes32(0), "upgrade cut must be committed");
        // The verifier is pinned by the release the bootstrap installs, not by a version-keyed map.
        assertEq(CTMRelease(chainContractAddress.currentRelease()).verifier(), address(testnetVerifier));

        // The WHOLE CTM domain ended up with the one CTM-bound executor — never left resting in
        // the migration. `migrate()` itself ends with the executor's `acceptCTMOwnership()`, so
        // the handover is COMPLETE when the call returns: no pending owner survives.
        assertEq(chainContractAddress.owner(), address(ctmExecutor), "CTM must be owned by its executor");
        assertEq(chainContractAddress.pendingOwner(), address(0), "the accept must happen inside migrate()");
        assertEq(
            ecosystemProxyAdmin.owner(),
            address(ctmExecutor),
            "CTM-domain ProxyAdmin must be owned by the CTM executor"
        );
        assertTrue(migration.executed(), "migration must be marked executed");
    }

    function test_migrate_isOneShot() public {
        _handOverAuthority();
        migration.migrate();

        vm.expectRevert(BootstrapAlreadyExecuted.selector);
        migration.migrate();
    }

    // ─────────────────────────── factory dependency publication ───────────────────────────

    /// @dev The committed cut's L2 transaction fails on every chain unless its factory
    ///      dependencies are on the CTM's supplier, so the edge refuses to commit until they are —
    ///      and commits, unchanged, once they are published.
    function test_migrate_requiresCommittedCutFactoryDepsPublished() public {
        bytes memory l2UpgradeCode = hex"c0de";
        RegistryBootstrapMigration gated = new RegistryBootstrapMigration(
            _manifestWithFactoryDeps(L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(l2UpgradeCode)))
        );
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(gated));
        ecosystemProxyAdmin.transferOwnership(address(gated));
        assertEq(chainContractAddress.L1_BYTECODES_SUPPLIER(), address(bytecodesSupplier));
        assertEq(bytecodesSupplier.evmPublishingBlock(keccak256(l2UpgradeCode)), 0, "fixture: not yet published");

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(l2UpgradeCode)));
        gated.migrate();
        assertFalse(gated.executed(), "a refused edge must stay unspent");
        assertEq(chainContractAddress.protocolVersion(), 0, "a refused edge must not move the CTM");

        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(l2UpgradeCode));

        gated.migrate();
        assertTrue(gated.executed(), "the same edge applies once the bytecode is published");
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        gated.validateApplied();
    }

    // ─────────────────────────── post-state verification ───────────────────────────

    /// @dev Stage 2 runs `validateApplied()` as a governance call: before the edge it must fail
    ///      loudly, so an incorrectly sequenced bundle cannot report success on an unapplied bootstrap.
    function test_revertWhen_validateAppliedBeforeMigrate() public {
        vm.expectRevert(BootstrapNotYetExecuted.selector);
        migration.validateApplied();
    }

    // ─────────────────────────── timer gating ───────────────────────────

    /// @dev The pinned timer proves stage 0 ran: an edge whose timer was never started must not
    ///      execute, regardless of authority.
    function test_revertWhen_timerNeverStarted() public {
        GovernanceUpgradeTimer unstarted = new GovernanceUpgradeTimer(0, 0, governor, governor);
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeTimer = PinnedContract({addr: address(unstarted), codehash: address(unstarted).codehash});
        RegistryBootstrapMigration gated = new RegistryBootstrapMigration(manifest);

        vm.prank(governor);
        chainContractAddress.transferOwnership(address(gated));
        ecosystemProxyAdmin.transferOwnership(address(gated));

        vm.expectRevert(TimerNotStarted.selector);
        gated.migrate();
    }

    function test_revertWhen_timerDeadlineNotYetPassed() public {
        GovernanceUpgradeTimer pending = new GovernanceUpgradeTimer(1000, 0, governor, governor);
        vm.prank(governor);
        pending.startTimer();
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeTimer = PinnedContract({addr: address(pending), codehash: address(pending).codehash});
        RegistryBootstrapMigration gated = new RegistryBootstrapMigration(manifest);

        vm.prank(governor);
        chainContractAddress.transferOwnership(address(gated));
        ecosystemProxyAdmin.transferOwnership(address(gated));

        // The window has not passed (no warp), so the edge is not yet executable.
        vm.expectRevert(DeadlineNotYetPassed.selector);
        gated.migrate();
    }

    // ─────────────────────────── source checks ───────────────────────────

    function test_revertWhen_authorityNotHandedOver() public {
        // Without ownership the migration could not perform any of the work; it must say so rather
        // than fail deep inside a proxy call.
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapAuthorityNotHeld.selector,
                address(chainContractAddress),
                chainContractAddress.owner()
            )
        );
        migration.migrate();
    }

    // ─────────────────────────── executor binding ───────────────────────────

    /// @dev The executors receive ALL the authority this edge moves, so a manifest naming one that
    ///      is bound elsewhere must be refused BEFORE the one-shot edge is spent — otherwise the
    ///      handover completes into an executor whose fixed entrypoints cannot drive what it owns.
    function test_revertWhen_ctmExecutorIsBoundToAnotherCtm() public {
        address foreignCtm = makeAddr("foreignCtm");
        CTMUpgradeExecutor foreignExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(foreignCtm),
            ecosystemProxyAdmin,
            ecoExecutor,
            Utils.transitionCodehash()
        );
        BootstrapManifest memory manifest = _manifest();
        manifest.ctmExecutor = PinnedContract({
            addr: address(foreignExecutor),
            codehash: address(foreignExecutor).codehash
        });

        RegistryBootstrapMigration mismatched = new RegistryBootstrapMigration(manifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(mismatched));
        ecosystemProxyAdmin.transferOwnership(address(mismatched));

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(foreignExecutor),
                address(chainContractAddress),
                foreignCtm
            )
        );
        mismatched.migrate();
        assertFalse(mismatched.executed(), "a refused edge must stay unspent");
    }

    function test_revertWhen_ctmExecutorIsBoundToAnotherProxyAdmin() public {
        ProxyAdmin foreignProxyAdmin = new ProxyAdmin();
        CTMUpgradeExecutor foreignExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            foreignProxyAdmin,
            ecoExecutor,
            Utils.transitionCodehash()
        );
        BootstrapManifest memory manifest = _manifest();
        manifest.ctmExecutor = PinnedContract({
            addr: address(foreignExecutor),
            codehash: address(foreignExecutor).codehash
        });

        RegistryBootstrapMigration mismatched = new RegistryBootstrapMigration(manifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(mismatched));
        ecosystemProxyAdmin.transferOwnership(address(mismatched));

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(foreignExecutor),
                address(ecosystemProxyAdmin),
                address(foreignProxyAdmin)
            )
        );
        mismatched.migrate();
    }

    function test_revertWhen_executorCodehashDrifted() public {
        bytes32 pinnedCodehash = address(ctmExecutor).codehash;
        vm.etch(address(ctmExecutor), hex"6001600155");
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(ctmExecutor),
                pinnedCodehash,
                address(ctmExecutor).codehash
            )
        );
        migration.migrate();
    }

    // ─────────────────────────── manifest shape ───────────────────────────

    /// @dev Two rows for one proxy would BOTH pass the source check (they compare against the same
    ///      pre-migration implementation) and the last would silently win — so the reviewed edge
    ///      and the executed edge would differ. Same rule {CoreRegistry} enforces.
    function test_migrate_runsFixedInitializeUpgradeExactlyOnce() public {
        // A second participating slot whose new implementation must reinitialize: the row
        // carries only a BOOLEAN, and the apply invokes the fixed argument-less selector
        // atomically with the swap.
        MockProxyUpgradeInitImpl initImpl = new MockProxyUpgradeInitImpl();
        TransparentUpgradeableProxy vtProxy = new TransparentUpgradeableProxy(
            implV31,
            address(ecosystemProxyAdmin),
            hex""
        );
        BootstrapManifest memory manifest = _manifest();
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = ProxyUpgradeRow({
            proxy: address(vtProxy),
            expectedOldImpl: implV31,
            implNew: PinnedContract({addr: address(initImpl), codehash: address(initImpl).codehash}),
            callInitializeUpgrade: true,
            admin: ProxyAdmin(address(0))
        });
        RegistryBootstrapMigration withInit = new RegistryBootstrapMigration(manifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(withInit));
        ecosystemProxyAdmin.transferOwnership(address(withInit));

        withInit.migrate();

        assertEq(
            MockProxyUpgradeInitImpl(address(vtProxy)).initializeUpgradeCalls(),
            1,
            "the fixed reinitializer must run exactly once, atomically with the swap"
        );
    }

    function test_revertWhen_manifestCarriesDuplicateProxyRows() public {
        BootstrapManifest memory manifest = _manifest();
        // A second slot pointing at the same proxy, with a different target.
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = ProxyUpgradeRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implV31,
            implNew: PinnedContract({addr: implV31, codehash: implV31.codehash}),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateProxyRow.selector, address(ecosystemProxy)));
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_manifestCarriesAZeroRowField() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.proxyUpgrades[uint256(CTMContract.ChainTypeManager)].expectedOldImpl = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_departingVersionIsNotTheExpectedOne() public {
        // A migration pinned for one ecosystem must refuse a differently-versioned one.
        RegistryBootstrapMigration staleMigration = new RegistryBootstrapMigration(
            _manifestWithExpectedVersion(chainContractAddress.protocolVersion() + 1)
        );
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(staleMigration));
        ecosystemProxyAdmin.transferOwnership(address(staleMigration));

        vm.expectRevert(
            abi.encodeWithSelector(
                OutdatedProtocolVersion.selector,
                chainContractAddress.protocolVersion(),
                chainContractAddress.protocolVersion() + 1
            )
        );
        staleMigration.migrate();
    }

    function test_revertWhen_proxyIsNotAtTheExpectedImplementation() public {
        // Someone moved the proxy to an implementation the row does not know before the migration
        // ran: the source check must catch it instead of silently re-pointing the proxy.
        ecosystemProxyAdmin.upgrade(ITransparentUpgradeableProxy(address(ecosystemProxy)), implUnknown);
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ecosystemProxy), implV31, implUnknown)
        );
        migration.migrate();
        assertFalse(migration.executed(), "a refused edge must stay unspent");
    }

    /// @dev A row whose proxy already sits at `implNew` is one a different administrator applied
    ///      first: the source check tolerates it, `applyRows` skips it (no re-apply, no event), and
    ///      the post-state check holds.
    function test_migrate_acceptsARowAlreadyAtItsNewImplementation() public {
        ecosystemProxyAdmin.upgrade(ITransparentUpgradeableProxy(address(ecosystemProxy)), implV32);
        _handOverAuthority();
        _completeCtmHandover(migration);
        migration.validate();

        vm.recordLogs();
        migration.migrate();
        assertEq(
            _countLogs(
                vm.getRecordedLogs(),
                address(migration),
                ProxyUpgradeRowLib.ProxyImplementationUpgraded.selector
            ),
            0,
            "an already-applied row must be skipped, not re-applied"
        );
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implV32);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the edge must otherwise complete");
        migration.validateApplied();
    }

    // ─────────────────────────── rows under a foreign ProxyAdmin ───────────────────────────

    /// @dev The notifier row names an admin the migration does not own: `migrate()` leaves it to
    ///      that administrator (logged), performs everything else, and the post-state gate holds the
    ///      bundle open until the administrator's own upgrade lands.
    function test_migrate_leavesForeignAdminRowToItsAdministrator_validateAppliedWaitsForIt() public {
        RegistryBootstrapMigration withNotifier = _deployAndAuthorize(_manifestWithNotifierRow());

        vm.expectEmit(true, true, true, true, address(withNotifier));
        emit ProxyUpgradeRowLib.ProxyRowLeftToAdministrator(address(notifierProxy), address(notifierAdmin));
        withNotifier.migrate();

        assertTrue(withNotifier.executed(), "the edge is spent");
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implV31, "the foreign row must be left untouched");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implV32, "the bound-admin row must still apply");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the edge must otherwise complete");
        assertEq(chainContractAddress.owner(), address(ctmExecutor), "authority still lands on the executor");
        assertEq(notifierAdmin.owner(), chainAdmin, "the foreign admin's ownership is not touched");

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(notifierProxy), implV32, implV31)
        );
        withNotifier.validateApplied();

        // The administrator applies its row through its own admin; the gate then passes.
        vm.prank(chainAdmin);
        notifierAdmin.upgrade(ITransparentUpgradeableProxy(address(notifierProxy)), implV32);
        withNotifier.validateApplied();
    }

    /// @dev The production order: the ChainAdmin's own upgrade call lands BEFORE the bundle (the
    ///      `ctm_admin_calls` protocol-ops runs right after the prepares), so the migration finds
    ///      the foreign row already at `implNew` — read through the row's own admin — and both the
    ///      source check and the post-state gate pass without the migration touching the row.
    function test_migrate_acceptsForeignAdminRowAppliedByItsAdministratorFirst() public {
        vm.prank(chainAdmin);
        notifierAdmin.upgrade(ITransparentUpgradeableProxy(address(notifierProxy)), implV32);
        RegistryBootstrapMigration withNotifier = _deployAndAuthorize(_manifestWithNotifierRow());
        _completeCtmHandover(withNotifier);
        withNotifier.validate();

        vm.recordLogs();
        withNotifier.migrate();
        Vm.Log[] memory logs = vm.getRecordedLogs();
        // Not owned, so the row is still the administrator's — and that is all that happens to it.
        assertEq(
            _countLogs(logs, address(withNotifier), ProxyUpgradeRowLib.ProxyRowLeftToAdministrator.selector),
            1,
            "the unowned row is left to its administrator"
        );
        assertEq(
            _countLogs(logs, address(withNotifier), ProxyUpgradeRowLib.ProxyImplementationUpgraded.selector),
            1,
            "only the bound-admin row is applied here"
        );
        assertEq(_liveImpl(notifierAdmin, notifierProxy), implV32);
        withNotifier.validateApplied();
    }

    /// @dev The source check reads a foreign row through ITS admin: an administrator that moved the
    ///      proxy somewhere the row does not know is caught before the one-shot edge is spent.
    function test_revertWhen_foreignAdminRowAtAnUnknownImplementation() public {
        vm.prank(chainAdmin);
        notifierAdmin.upgrade(ITransparentUpgradeableProxy(address(notifierProxy)), implUnknown);
        RegistryBootstrapMigration withNotifier = _deployAndAuthorize(_manifestWithNotifierRow());

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(notifierProxy), implV31, implUnknown)
        );
        withNotifier.migrate();
        assertFalse(withNotifier.executed(), "a refused edge must stay unspent");
        assertEq(chainContractAddress.protocolVersion(), 0, "a refused edge must not move the CTM");
    }

    function test_revertWhen_pinnedImplementationCodehashDrifted() public {
        // The pin protects the address: replacing the code at `implNew` must be rejected.
        bytes32 pinnedCodehash = implV32.codehash;
        vm.etch(implV32, hex"6001600155");
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(RegistryCodehashMismatch.selector, implV32, pinnedCodehash, implV32.codehash)
        );
        migration.migrate();
    }

    function test_revertWhen_releaseDoesNotRunTheAnchoredCode() public {
        // The anchor this edge installs and the release it vouches for cannot be mismatched:
        // replacing the release's code makes the migration refuse before spending itself.
        bytes32 anchoredCodehash = address(genesisRelease).codehash;
        vm.etch(address(genesisRelease), hex"600045");
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(genesisRelease),
                anchoredCodehash,
                address(genesisRelease).codehash
            )
        );
        migration.migrate();
    }

    function test_manifestHashCommitsToThePinnedEdge() public view {
        assertEq(migration.manifestHash(), keccak256(abi.encode(_manifest())));
    }

    /// @dev The proxy `Upgraded` events fire first, so the bootstrap event is located by scanning
    ///      rather than by expecting it to be the next one emitted.
    function _assertBootstrappedEventEmitted() internal {
        Vm.Log[] memory logs = vm.getRecordedLogs();
        bytes32 topic = keccak256("EcosystemBootstrapped(address,address,uint256)");
        bool found;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].emitter == address(migration) && logs[i].topics[0] == topic) {
                assertEq(address(uint160(uint256(logs[i].topics[1]))), address(chainContractAddress));
                assertEq(address(uint160(uint256(logs[i].topics[2]))), address(genesisRelease));
                assertEq(abi.decode(logs[i].data, (uint256)), newVersion);
                found = true;
            }
        }
        assertTrue(found, "EcosystemBootstrapped must be emitted");
    }

    function _manifestWithExpectedVersion(
        uint256 _expectedVersion
    ) internal view returns (BootstrapManifest memory manifest) {
        manifest = _manifest();
        manifest.expectedProtocolVersion = _expectedVersion;
    }
}

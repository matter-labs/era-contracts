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
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    BootstrapAlreadyExecuted,
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    DeadlineNotYetPassed,
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

/// @notice Tests the single source-checked edge from a pre-registry ecosystem into the
///         registry-driven model: implementation swaps, provenance anchor + genesis release,
///         version edge, and the authority handover to the bound executors.
/// @dev Driven against a REAL `EraChainTypeManager` and a real OpenZeppelin `ProxyAdmin` — the two
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
        ecosystemProxyAdmin = new ProxyAdmin();
        ecosystemProxy = new TransparentUpgradeableProxy(implV31, address(ecosystemProxyAdmin), hex"");

        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");
        upgradeCutInit = makeAddr("upgradeCutInit");
        vm.etch(upgradeCutInit, hex"600043");

        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            makeAddr("emergencyUpgradeBoard"),
            IChainTypeManager(address(chainContractAddress)),
            ecosystemProxyAdmin,
            Utils.transitionCodehash()
        );
        ecoExecutor = new EcosystemUpgradeExecutor(
            governor,
            makeAddr("emergencyUpgradeBoard"),
            ecosystemProxyAdmin,
            Utils.coreRegistryCodehash()
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
                    bootloaderHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    defaultAccountHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    evmEmulatorHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(7)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                // Length-checked inventory; content is irrelevant to this fixture.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
            })
        );
    }

    function _manifest() internal view returns (BootstrapManifest memory) {
        // The one participating slot in the enum-indexed CTM-domain inventory: the CTM's own
        // implementation swap. The remaining slots stay inert (explicitly not upgraded).
        ProxyUpgradeRow[] memory upgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        upgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implV31,
            implNew: PinnedContract({addr: implV32, codehash: implV32.codehash}),
            callInitializeUpgrade: false
        });
        Diamond.FacetCut[] memory noFacetCuts = new Diamond.FacetCut[](0);
        return
            BootstrapManifest({
                ctm: address(chainContractAddress),
                expectedProtocolVersion: chainContractAddress.protocolVersion(),
                ctmProxyAdmin: ecosystemProxyAdmin,
                proxyUpgrades: upgrades,
                currentRelease: PinnedContract({addr: address(genesisRelease), codehash: Utils.releaseCodehash()}),
                newProtocolVersion: newVersion,
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeCut: Diamond.DiamondCutData({
                    facetCuts: noFacetCuts,
                    initAddress: upgradeCutInit,
                    initCalldata: hex""
                }),
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

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_migrate_performsTheWholeEdgeAndHandsOverAuthority() public {
        _handOverAuthority();
        uint256 oldVersion = chainContractAddress.protocolVersion();

        vm.recordLogs();
        migration.migrate();
        _assertBootstrappedEventEmitted();

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
            makeAddr("emergencyUpgradeBoard2"),
            IChainTypeManager(foreignCtm),
            ecosystemProxyAdmin,
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
            makeAddr("emergencyUpgradeBoard2"),
            IChainTypeManager(address(chainContractAddress)),
            foreignProxyAdmin,
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
            callInitializeUpgrade: true
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
            callInitializeUpgrade: false
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
        // Someone moved the proxy on before the migration ran: the source check must catch it
        // instead of silently re-pointing the proxy backwards.
        ecosystemProxyAdmin.upgrade(ITransparentUpgradeableProxy(address(ecosystemProxy)), implV32);
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ecosystemProxy), implV31, implV32)
        );
        migration.migrate();
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

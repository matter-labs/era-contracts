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

import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/CTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/EcosystemUpgradeExecutor.sol";
import {
    CTMReleaseFactory,
    CTMTransitionFactory,
    CoreRegistryFactory,
    RegistryBootstrapMigrationFactory
} from "contracts/upgrades/registry/CTMRegistryFactory.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/RegistryBootstrapMigration.sol";
import {EcosystemContractRow} from "contracts/upgrades/registry/ICoreRegistry.sol";
import {GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    BootstrapAlreadyExecuted,
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    EcosystemImplMismatch,
    NotFactoryDeployed,
    RegistryCodehashMismatch,
    RegistryDuplicateProxyRow,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";

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
    RegistryBootstrapMigrationFactory internal migrationFactory;
    RegistryBootstrapMigration internal migration;
    CTMReleaseFactory internal releaseFactory;
    CTMUpgradeExecutor internal ctmExecutor;
    EcosystemUpgradeExecutor internal ecoExecutor;
    ProxyAdmin internal ecosystemProxyAdmin;

    CTMRelease internal genesisRelease;
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

        releaseFactory = new CTMReleaseFactory();
        migrationFactory = new RegistryBootstrapMigrationFactory();
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            makeAddr("breakGlass"),
            IChainTypeManager(address(chainContractAddress)),
            new CTMTransitionFactory()
        );
        ecoExecutor = new EcosystemUpgradeExecutor(
            governor,
            makeAddr("breakGlass"),
            ecosystemProxyAdmin,
            new CoreRegistryFactory()
        );

        newVersion = SemVer.packSemVer(0, 1, 0);
        genesisRelease = _deployAttestedRelease();
        migration = RegistryBootstrapMigration(migrationFactory.deployOrGetMigration(_manifest()));
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    /// @dev Deploys the genesis release through the real factory AND attests it on the CTM's
    ///      canonical (mocked) factory, so the CTM accepts it at `setCurrentRelease`.
    function _deployAttestedRelease() internal returns (CTMRelease result) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({
                facet: facetCuts[i].facet,
                isFreezable: facetCuts[i].isFreezable,
                selectors: facetCuts[i].selectors,
                codehash: facetCuts[i].facet.codehash
            });
        }
        result = CTMRelease(
            releaseFactory.deployOrGetRelease(
                CTMRelease.ReleaseManifest({
                    diamondInit: diamondInit,
                    diamondInitCodehash: diamondInit.codehash,
                    verifier: address(testnetVerifier),
                    verifierCodehash: address(testnetVerifier).codehash,
                    genesisFacets: genesisFacets,
                    bootloaderHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    defaultAccountHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    evmEmulatorHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisUpgrade: genesisUpgradeAddr,
                    genesisUpgradeCodehash: genesisUpgradeAddr.codehash,
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(7)),
                    genesisIndexRepeatedStorageChanges: 54
                })
            )
        );
        vm.mockCall(
            Utils.TEST_RELEASE_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("deployedFor(bytes32)")), result.manifestHash()),
            abi.encode(address(result))
        );
    }

    function _manifest() internal view returns (RegistryBootstrapMigration.BootstrapManifest memory) {
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](1);
        rows[0] = EcosystemContractRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implV31,
            implNew: implV32,
            implNewCodehash: implV32.codehash
        });
        Diamond.FacetCut[] memory noFacetCuts = new Diamond.FacetCut[](0);
        return
            RegistryBootstrapMigration.BootstrapManifest({
                ctm: address(chainContractAddress),
                expectedProtocolVersion: chainContractAddress.protocolVersion(),
                ctmProxyAdmin: ecosystemProxyAdmin,
                proxyRows: rows,
                releaseFactory: Utils.TEST_RELEASE_FACTORY,
                releaseFactoryCodehash: Utils.TEST_RELEASE_FACTORY.codehash,
                currentRelease: address(genesisRelease),
                newProtocolVersion: newVersion,
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeCut: Diamond.DiamondCutData({
                    facetCuts: noFacetCuts,
                    initAddress: upgradeCutInit,
                    initCalldata: hex""
                }),
                upgradeCutInitCodehash: upgradeCutInit.codehash,
                ctmExecutor: address(ctmExecutor),
                ctmExecutorCodehash: address(ctmExecutor).codehash,
                ecosystemExecutor: address(ecoExecutor),
                ecosystemExecutorCodehash: address(ecoExecutor).codehash
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
        // Final call of the governance bundle: the executor claims the CTM it was nominated for.
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();

        // The ecosystem proxy moved to its pinned implementation.
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implV32,
            "proxy must point at the pinned implementation"
        );
        // The registry anchors are installed and the version edge committed.
        assertEq(chainContractAddress.releaseFactory(), Utils.TEST_RELEASE_FACTORY, "anchor must be installed");
        assertEq(chainContractAddress.currentRelease(), address(genesisRelease), "release must be pinned");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "version must be bumped");
        assertTrue(chainContractAddress.upgradeCutHash(oldVersion) != bytes32(0), "upgrade cut must be committed");
        // The verifier is pinned by the release the bootstrap installs, not by a version-keyed map.
        assertEq(CTMRelease(chainContractAddress.currentRelease()).verifier(), address(testnetVerifier));

        // Authority ended up with the executors — never left resting in the migration.
        assertEq(chainContractAddress.owner(), address(ctmExecutor), "CTM must be owned by its executor");
        assertEq(ecosystemProxyAdmin.owner(), address(ecoExecutor), "ProxyAdmin must be owned by its executor");
        assertTrue(migration.executed(), "migration must be marked executed");
    }

    function test_migrate_isOneShot() public {
        _handOverAuthority();
        migration.migrate();
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();

        vm.expectRevert(BootstrapAlreadyExecuted.selector);
        migration.migrate();
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
            makeAddr("breakGlass2"),
            IChainTypeManager(foreignCtm),
            new CTMTransitionFactory()
        );
        RegistryBootstrapMigration.BootstrapManifest memory manifest = _manifest();
        manifest.ctmExecutor = address(foreignExecutor);
        manifest.ctmExecutorCodehash = address(foreignExecutor).codehash;

        RegistryBootstrapMigration mismatched = RegistryBootstrapMigration(
            migrationFactory.deployOrGetMigration(manifest)
        );
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

    function test_revertWhen_ecosystemExecutorIsBoundToAnotherProxyAdmin() public {
        ProxyAdmin foreignProxyAdmin = new ProxyAdmin();
        EcosystemUpgradeExecutor foreignExecutor = new EcosystemUpgradeExecutor(
            governor,
            makeAddr("breakGlass2"),
            foreignProxyAdmin,
            new CoreRegistryFactory()
        );
        RegistryBootstrapMigration.BootstrapManifest memory manifest = _manifest();
        manifest.ecosystemExecutor = address(foreignExecutor);
        manifest.ecosystemExecutorCodehash = address(foreignExecutor).codehash;

        RegistryBootstrapMigration mismatched = RegistryBootstrapMigration(
            migrationFactory.deployOrGetMigration(manifest)
        );
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
    function test_revertWhen_manifestCarriesDuplicateProxyRows() public {
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](2);
        rows[0] = EcosystemContractRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implV31,
            implNew: implV32,
            implNewCodehash: implV32.codehash
        });
        rows[1] = EcosystemContractRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implV31,
            implNew: implV31,
            implNewCodehash: implV31.codehash
        });
        RegistryBootstrapMigration.BootstrapManifest memory manifest = _manifest();
        manifest.proxyRows = rows;

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateProxyRow.selector, address(ecosystemProxy)));
        migrationFactory.deployOrGetMigration(manifest);
    }

    function test_revertWhen_manifestCarriesAZeroRowField() public {
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](1);
        rows[0] = EcosystemContractRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: address(0),
            implNew: implV32,
            implNewCodehash: implV32.codehash
        });
        RegistryBootstrapMigration.BootstrapManifest memory manifest = _manifest();
        manifest.proxyRows = rows;

        vm.expectRevert(ZeroAddress.selector);
        migrationFactory.deployOrGetMigration(manifest);
    }

    function test_revertWhen_departingVersionIsNotTheExpectedOne() public {
        // A migration pinned for one ecosystem must refuse a differently-versioned one.
        RegistryBootstrapMigration staleMigration = RegistryBootstrapMigration(
            migrationFactory.deployOrGetMigration(
                _manifestWithExpectedVersion(chainContractAddress.protocolVersion() + 1)
            )
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
            abi.encodeWithSelector(EcosystemImplMismatch.selector, address(ecosystemProxy), implV31, implV32)
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

    function test_revertWhen_releaseIsNotAttestedByTheInstalledFactory() public {
        // A release the pinned anchor never attested must not become `currentRelease`.
        vm.mockCall(
            Utils.TEST_RELEASE_FACTORY,
            abi.encodeWithSelector(bytes4(keccak256("deployedFor(bytes32)")), genesisRelease.manifestHash()),
            abi.encode(address(0))
        );
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(NotFactoryDeployed.selector, address(genesisRelease)));
        migration.migrate();
    }

    // ─────────────────────────────── factory ───────────────────────────────

    function test_factoryIsIdempotentPerManifest() public {
        address again = migrationFactory.deployOrGetMigration(_manifest());
        assertEq(again, address(migration), "same manifest must resolve to the same instance");
        assertEq(
            migration.manifestHash(),
            keccak256(abi.encode(_manifest())),
            "manifest hash must commit to the pinned edge"
        );
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
    ) internal view returns (RegistryBootstrapMigration.BootstrapManifest memory manifest) {
        manifest = _manifest();
        manifest.expectedProtocolVersion = _expectedVersion;
    }
}

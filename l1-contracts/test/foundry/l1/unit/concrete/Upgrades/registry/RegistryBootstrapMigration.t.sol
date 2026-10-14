// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {Vm} from "forge-std/Vm.sol";

import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {IL2DelegateCalldataComposer} from "contracts/upgrades/registry/objects/IL2DelegateCalldataComposer.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {ServerNotifier} from "contracts/governance/ServerNotifier.sol";
import {IBootstrapUpgrade} from "contracts/upgrades/IBootstrapUpgrade.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {Call} from "contracts/governance/Common.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {BYTECODE_INFO_LENGTH} from "contracts/common/libraries/ZKSyncOSBytecodeInfo.sol";
import {
    MAX_ALLOWED_MINOR_VERSION_DELTA,
    MAX_NEW_FACTORY_DEPS,
    UPGRADE_TX_MAX_GAS_LIMIT,
    REQUIRED_L2_GAS_PRICE_PER_PUBDATA,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_FORCE_DEPLOYER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {
    BootstrapAlreadyExecuted,
    BootstrapAuthorityNotHeld,
    BootstrapExecutorNotBound,
    BootstrapExecutorOwnerMismatch,
    BootstrapNominationPending,
    BootstrapNotYetExecuted,
    BootstrapServerNotifierNotBound,
    BootstrapServerNotifierRowMissing,
    DeadlineNotYetPassed,
    L2BytecodeNotPublished,
    L2BytecodeInfoLength,
    L2PlanNeedsDelegate,
    L2PlanTooManyFactoryDeps,
    MigrationPaused,
    PatchCannotCarryL2Upgrade,
    ProxyUpgradeRowMismatch,
    RegistryEmptySelectors,
    RegistryTargetHasNoCode,
    RegistryDuplicateProxyRow,
    TimerNotStarted,
    TransitionDeadlineBeforeUpgrade,
    TransitionDeadlineZero,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    NewProtocolMajorVersionNotZero,
    PreviousProtocolMajorVersionNotZero,
    ProtocolVersionMinorDeltaTooBig,
    ProtocolVersionTooSmall
} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {
    AuthoredL2Plan,
    BootstrapManifest,
    L2UpgradePlan,
    ProxyUpgradeRow,
    GenesisFacet,
    ReleaseGenesisData,
    ReleaseManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L2_ECOSYSTEM_CONTRACT_COUNT,
    L2EcosystemContract
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
///         version edge, the on-chain composed upgrade cut, and the authority handover to the
///         bound executors.
/// @dev Driven against a REAL `ChainTypeManager` and a real OpenZeppelin `ProxyAdmin` — the two
///      contracts whose ownership the migration actually needs — rather than mocks, because the
///      property under test IS the authority movement.
contract RegistryBootstrapMigrationTest is ChainTypeManagerTest {
    RegistryBootstrapMigration internal migration;
    CTMUpgradeExecutor internal ctmExecutor;
    CoreUpgradeExecutor internal coreExecutor;
    EcosystemUpgradeExecutor internal coordinator;
    /// @dev The CTM domain's own admin (the manifest's `ctmProxyAdmin`) and the ecosystem's (the
    ///      core executor's), as in production.
    ProxyAdmin internal ctmProxyAdmin;
    ProxyAdmin internal ecosystemProxyAdmin;

    CTMRelease internal genesisRelease;
    GovernanceUpgradeTimer internal upgradeTimer;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    address internal implV31;
    address internal implV32;
    address internal implUnknown;
    // The pre-bootstrap ServerNotifier shape: a real notifier proxy under its OWN ProxyAdmin, both
    // owned by the chain admin. Its one-time handover to the CTM domain is a precondition of the
    // edge ({docs/upgrade-stage-lifecycle.md}); the fixture performs it in `setUp`.
    address internal chainAdmin;
    ProxyAdmin internal notifierAdmin;
    TransparentUpgradeableProxy internal notifierProxy;
    address internal notifierImplOld;
    address internal notifierImplNew;
    address internal genesisUpgradeAddr;
    /// @dev The pinned init target of the committed cut. This fixture never executes the cut (the
    ///      CTM only commits its hash), so a distinct etched stand-in is all the pin needs.
    address internal upgradeEngine;
    /// @dev The pinned delegate-calldata composer of a plan-bearing manifest: a test-only stand-in
    ///      returning `DELEGATE_CALLDATA` regardless of its inputs, so this suite can pin a real
    ///      composer without a version-specific L2 migration behind it.
    FixedDelegateCalldataComposer internal delegateComposer;

    uint256 internal newVersion;

    bytes internal constant DELEGATE_CALLDATA = hex"beef";
    // Dummy EVM bytecodes standing in for the L2 artifacts the edge installs (see {L2PlanFixtures}):
    // the authored upgrade delegate, and the system-proxied member a genesis release's table can
    // carry (implementation + proxy shell).
    bytes internal constant DELEGATE_CODE = hex"aa01";
    bytes internal constant BRIDGEHUB_IMPL_CODE = hex"dd01";
    bytes internal constant SYSTEM_PROXY_CODE = hex"dd00";
    /// @dev A nonzero schedule, so its pass-through into the composed proposal is observable.
    uint256 internal constant PLAN_UPGRADE_TIMESTAMP = 1234567;

    function setUp() public {
        deploy();
        // `setNewVersionUpgrade` requires migrations paused — the window stage 0 opens and stage 2
        // closes. The bootstrap edge replaces stage 1, so it runs inside that same window.
        _mockMigrationPausedFromBridgehub();

        implV31 = address(new ImplV31());
        implV32 = address(new ImplV32());
        implUnknown = address(new ImplUnknown());
        ctmProxyAdmin = new ProxyAdmin();
        ctmDomainProxy = new TransparentUpgradeableProxy(implV31, address(ctmProxyAdmin), hex"");
        chainAdmin = makeAddr("chainAdmin");
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(chainAdmin);
        notifierImplOld = address(new ServerNotifier());
        notifierImplNew = address(new ServerNotifier());
        notifierProxy = _deployNotifier();

        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");
        upgradeEngine = makeAddr("upgradeEngine");
        vm.etch(upgradeEngine, hex"600043");
        delegateComposer = new FixedDelegateCalldataComposer(DELEGATE_CALLDATA);

        // The coordinator is deployed first: the CTM executor is constructed answering to it, and
        // the edge checks that binding.
        ecosystemProxyAdmin = new ProxyAdmin();
        coreExecutor = new CoreUpgradeExecutor(governor, ecosystemProxyAdmin);
        coordinator = new EcosystemUpgradeExecutor(governor, coreExecutor);
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            address(coordinator)
        );

        // Stage 1's bindings and ecosystem handover, which precede `migrate()` in the same
        // transaction; the suites that drop one of them undo it explicitly.
        vm.startPrank(governor);
        coreExecutor.setCoordinator(address(coordinator));
        coordinator.setCTMExecutor(ctmExecutor);
        vm.stopPrank();
        ecosystemProxyAdmin.transferOwnership(address(coreExecutor));
        _handOverNotifier(notifierProxy);

        newVersion = SemVer.packSemVer(0, 1, 0);
        // The pinned timer gates `migrate()`: stage 0 starts it, the edge runs after its window.
        // Zero delays make the window pass immediately in the fixture.
        upgradeTimer = new GovernanceUpgradeTimer(0, 0, governor, governor);
        vm.prank(governor);
        upgradeTimer.startTimer();
        // The release constructor reads each facet's self-description (see the shared fixture).
        _mockFacetSelfDescriptions(facetCuts);
        // An empty L2 table: the default edge derives no L2 deployments.
        genesisRelease = _deployRelease(new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT));
        migration = new RegistryBootstrapMigration(_manifest());
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    /// @dev Stage 2's unpause, as the fixture's mocked ChainAssetHandler sees it (the fixture
    ///      mocks the handler paused for the whole edge; see `_mockMigrationPausedFromBridgehub`).
    function _mockMigrationsUnpaused() internal {
        vm.mockCall(
            makeAddr("mockChainAssetHandler"),
            abi.encodeWithSignature("migrationPausedFor(address)"),
            abi.encode(false)
        );
    }

    /// @dev A release pinning the fixture's facets, verifier and (ZKsync OS) DiamondInit over
    ///      `_l2BytecodeInfos`, behind the fixture's system-proxy shell.
    function _deployRelease(bytes[] memory _l2BytecodeInfos) internal returns (CTMRelease result) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({facet: facetCuts[i].facet, isFreezable: facetCuts[i].isFreezable});
        }
        result = new CTMRelease(
            ReleaseManifest({
                // The version the edge moves the CTM to is its genesis release's own.
                protocolVersion: newVersion,
                diamondInit: diamondInit,
                verifier: address(testnetVerifier),
                genesisUpgrade: genesisUpgradeAddr,
                genesisFacets: genesisFacets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(uint256(1)),
                    // ChainTypeManager requires the commitment to be exactly 1.
                    genesisIndexRepeatedStorageChanges: 54
                }),
                l2BytecodeInfos: _l2BytecodeInfos,
                l2SystemProxyBytecodeInfo: L2PlanFixtures.bytecodeInfo(SYSTEM_PROXY_CODE)
            })
        );
    }

    /// @dev A genesis release whose table carries one implementation row (the L2 Bridgehub), so
    ///      the derived L2 set is nonempty. Its dependencies are the implementation and the proxy
    ///      shell.
    function _deployTableRelease() internal returns (CTMRelease) {
        bytes[] memory table = new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
        table[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.bytecodeInfo(BRIDGEHUB_IMPL_CODE);
        return _deployRelease(table);
    }

    /// @dev The default edge is L1-only: the genesis release's table is empty and nothing is
    ///      authored, so the composed cut carries the all-zero L2 transaction `BaseZkSyncUpgrade`
    ///      skips.
    function _manifest() internal view returns (BootstrapManifest memory) {
        return _manifestWithL2Plan(_emptyL2Plan());
    }

    function _emptyL2Plan() internal pure returns (AuthoredL2Plan memory) {
        return L2PlanFixtures.emptyPlan();
    }

    /// @dev The minimal authored input with an L2 side: the delegate's bytecode info (the object
    ///      constructs its Unsafe deployment at the bytecode-derived address and pins its bytecode
    ///      as the one factory dependency) and the pinned composer defining its calldata.
    function _authoredPlan() internal view returns (AuthoredL2Plan memory) {
        return L2PlanFixtures.delegatePlan(DELEGATE_CODE, address(delegateComposer));
    }

    /// @dev Every bytecode an edge toward `_deployTableRelease()` installs: the delegate plus the
    ///      table row's implementation and proxy shell.
    function _tableCodes() internal pure returns (bytes[] memory) {
        return L2PlanFixtures.codes(DELEGATE_CODE, BRIDGEHUB_IMPL_CODE, SYSTEM_PROXY_CODE);
    }

    /// @dev `_authoredPlan()` toward `_tableRelease` with a nonzero schedule.
    function _tableManifest(CTMRelease _tableRelease) internal view returns (BootstrapManifest memory manifest) {
        manifest = _manifestWithL2Plan(_authoredPlan());
        manifest.currentRelease = address(_tableRelease);
        manifest.upgradeTimestamp = PLAN_UPGRADE_TIMESTAMP;
    }

    function _manifestWithL2Plan(AuthoredL2Plan memory _l2Plan) internal view returns (BootstrapManifest memory) {
        // The one participating slot in the enum-indexed CTM-domain inventory: the CTM's own
        // implementation swap. The remaining slots stay inert (explicitly not upgraded).
        ProxyUpgradeRow[] memory upgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        upgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: address(ctmDomainProxy),
            expectedOldImpl: implV31,
            implNew: implV32,
            callInitializeUpgrade: false
        });
        upgrades[uint256(CTMContract.ServerNotifier)] = _notifierRow(notifierProxy);
        return
            BootstrapManifest({
                ctm: address(chainContractAddress),
                expectedProtocolVersion: chainContractAddress.protocolVersion(),
                ctmProxyAdmin: ctmProxyAdmin,
                proxyUpgrades: upgrades,
                currentRelease: address(genesisRelease),
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeEngine: upgradeEngine,
                l2Plan: _l2Plan,
                upgradeTimestamp: 0,
                ctmExecutor: address(ctmExecutor),
                coreExecutor: address(coreExecutor),
                governance: governor,
                coordinator: address(coordinator),
                upgradeTimer: address(upgradeTimer)
            });
    }

    /// @dev The zero pin: no composer (the delegate is called with empty calldata).
    /// @dev The L2 transaction the edge's FINAL plan composes, assembled here from the constants
    ///      the composer reads rather than through the library under test, so the equality below
    ///      is a real check of the composition.
    function _expectedL2Tx(
        L2UpgradePlan memory _plan,
        bytes memory _delegateCalldata
    ) internal view returns (L2CanonicalTransaction memory transaction) {
        transaction = L2CanonicalTransactionLib.emptyL2CanonicalTransaction();
        // VM identity comes off the release's DiamondInit, which the shared fixture builds with true.
        transaction.txType = ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = UPGRADE_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(newVersion));
        transaction.nonce = minor;
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_plan.deployments, _plan.delegateTo, _delegateCalldata)
        );
        transaction.factoryDeps = _plan.factoryDepHashes;
    }

    /// @dev No facet cuts; the pinned engine's `upgradeFromBootstrap(migration)` as the init — the
    ///      engine reads the version edge, the schedule, the release and the L2 plan from the
    ///      object itself.
    function _expectedCut(RegistryBootstrapMigration _migration) internal view returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: upgradeEngine,
                initCalldata: abi.encodeCall(IBootstrapUpgrade.upgradeFromBootstrap, (address(_migration)))
            });
    }

    /// @dev Decodes an `upgradeFromBootstrap(address)` init payload; external so the selector can
    ///      be sliced off calldata.
    function decodeUpgradeInit(bytes calldata _initCalldata) external pure returns (address) {
        assertEq(
            bytes32(bytes4(_initCalldata[:4])),
            bytes32(IBootstrapUpgrade.upgradeFromBootstrap.selector),
            "init selector"
        );
        return abi.decode(_initCalldata[4:], (address));
    }

    /// @dev Decodes a `forceDeployAndUpgradeUniversal` payload.
    function decodeUniversalCall(
        bytes calldata _data
    ) external pure returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory, address, bytes memory) {
        assertEq(
            bytes32(bytes4(_data[:4])),
            bytes32(IComplexUpgrader.forceDeployAndUpgradeUniversal.selector),
            "L2 tx selector"
        );
        return abi.decode(_data[4:], (IComplexUpgrader.UniversalContractUpgradeInfo[], address, bytes));
    }

    /// @dev The governance bundle this object replaces stage 1 with: nominate the CTM, hand over
    ///      the ProxyAdmin, migrate. Three calls instead of ~15.
    function _handOverAuthority() internal {
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(migration));
        ctmProxyAdmin.transferOwnership(address(migration));
    }

    /// @dev A real notifier proxy in its pre-bootstrap shape: under `notifierAdmin`, owned by the
    ///      chain admin, serving the fixture CTM, and set as the CTM's notifier (governance still
    ///      owns the CTM before the edge).
    function _deployNotifier() internal returns (TransparentUpgradeableProxy proxy) {
        proxy = new TransparentUpgradeableProxy(
            notifierImplOld,
            address(notifierAdmin),
            abi.encodeCall(ServerNotifier.initialize, (chainAdmin))
        );
        vm.prank(chainAdmin);
        ServerNotifier(address(proxy)).setChainTypeManager(IChainTypeManager(address(chainContractAddress)));
        vm.prank(governor);
        chainContractAddress.setServerNotifier(address(proxy));
    }

    /// @dev The mandatory notifier row over `_proxy`.
    function _notifierRow(TransparentUpgradeableProxy _proxy) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: address(_proxy),
                expectedOldImpl: notifierImplOld,
                implNew: notifierImplNew,
                callInitializeUpgrade: false
            });
    }

    /// @dev The ChainAdmin's half of the handover: the proxy moves under the CTM-domain ProxyAdmin.
    function _moveNotifierUnderTheCtmProxyAdmin(TransparentUpgradeableProxy _proxy) internal {
        vm.prank(chainAdmin);
        notifierAdmin.changeProxyAdmin(ITransparentUpgradeableProxy(address(_proxy)), address(ctmProxyAdmin));
    }

    /// @dev The ChainAdmin's half of the handover: it nominates the CTM executor as owner.
    function _nominateExecutorForNotifier(TransparentUpgradeableProxy _proxy) internal {
        vm.prank(chainAdmin);
        Ownable2Step(address(_proxy)).transferOwnership(address(ctmExecutor));
    }

    /// @dev Governance's half: the executor accepts through `forward`.
    function _acceptNotifierThroughTheExecutor(TransparentUpgradeableProxy _proxy) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(_proxy), value: 0, data: abi.encodeCall(Ownable2Step.acceptOwnership, ())});
        vm.prank(governor);
        ctmExecutor.forward(calls);
    }

    /// @dev The whole one-time handover, in production order.
    function _handOverNotifier(TransparentUpgradeableProxy _proxy) internal {
        _moveNotifierUnderTheCtmProxyAdmin(_proxy);
        _nominateExecutorForNotifier(_proxy);
        _acceptNotifierThroughTheExecutor(_proxy);
    }

    /// @dev `_manifest()` over a FRESH notifier, made the CTM's, on which no step of the handover
    ///      has happened yet.
    function _manifestWithFreshNotifier()
        internal
        returns (BootstrapManifest memory manifest, TransparentUpgradeableProxy fresh)
    {
        fresh = _deployNotifier();
        manifest = _manifest();
        manifest.proxyUpgrades[uint256(CTMContract.ServerNotifier)] = _notifierRow(fresh);
    }

    /// @dev Deploys a migration for `_bootstrapManifest` and hands it the authority `_handOverAuthority`
    ///      hands the fixture's.
    function _deployAndAuthorize(
        BootstrapManifest memory _bootstrapManifest
    ) internal returns (RegistryBootstrapMigration deployed) {
        deployed = new RegistryBootstrapMigration(_bootstrapManifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(deployed));
        ctmProxyAdmin.transferOwnership(address(deployed));
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

        // The object's own post-state check covers the whole edge (version, release pin, authority
        // landing); the granular asserts below then pin the exact expected values.
        _mockMigrationsUnpaused();
        migration.validateApplied();

        // The ecosystem proxy moved to the implementation the row names.
        assertEq(
            ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ctmDomainProxy))),
            implV32,
            "proxy must point at the row's implementation"
        );
        // The release the edge names is the one the CTM ends up pointing at, and the version edge
        // is committed with the cut the object composes on-chain.
        assertEq(chainContractAddress.currentRelease(), address(genesisRelease), "release must be installed");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "version must be bumped");
        assertEq(
            chainContractAddress.upgradeCutHash(oldVersion),
            keccak256(abi.encode(migration.upgradeCut())),
            "the composed cut must be committed"
        );
        // The verifier is pinned by the release the bootstrap installs, not by a version-keyed map.
        assertEq(CTMRelease(chainContractAddress.currentRelease()).verifier(), address(testnetVerifier));

        // The WHOLE CTM domain ended up with the one CTM-bound executor — never left resting in
        // the migration. `migrate()` itself ends with the executor's `acceptCTMOwnership()`, so
        // the handover is COMPLETE when the call returns: no pending owner survives.
        assertEq(chainContractAddress.owner(), address(ctmExecutor), "CTM must be owned by its executor");
        assertEq(chainContractAddress.pendingOwner(), address(0), "the accept must happen inside migrate()");
        assertEq(
            ctmProxyAdmin.owner(),
            address(ctmExecutor),
            "CTM-domain ProxyAdmin must be owned by the CTM executor"
        );
        assertTrue(migration.executed(), "migration must be marked executed");
        // The notifier row applied through the CTM-domain ProxyAdmin, like the CTM's own.
        assertEq(_liveImpl(ctmProxyAdmin, notifierProxy), notifierImplNew, "the notifier row must be applied");
        assertEq(
            Ownable2Step(address(notifierProxy)).owner(),
            address(ctmExecutor),
            "the notifier stays the executor's"
        );
    }

    function test_migrate_isOneShot() public {
        _handOverAuthority();
        migration.migrate();

        vm.expectRevert(BootstrapAlreadyExecuted.selector);
        migration.migrate();
    }

    // ─────────────────────────────── composed payload ───────────────────────────────

    /// @dev The committed cut carries nothing but the reference back to this object: no facet cuts,
    ///      the pinned engine's `upgradeFromBootstrap(this)` init. What the engine then reads is
    ///      served here — the manifest's version edge and schedule, and, against a genesis release
    ///      whose table carries a row, the L2 transaction built from the FINAL plan, whose delegate
    ///      calldata the pinned composer defines from that release and the CTM's Bridgehub.
    function test_upgradeCut_namesTheEngineOverThisObjectAndServesTheComposedL2Tx() public {
        CTMRelease tableRelease = _deployTableRelease();
        RegistryBootstrapMigration composed = new RegistryBootstrapMigration(_tableManifest(tableRelease));
        L2UpgradePlan memory plan = composed.l2Plan();

        Diamond.DiamondCutData memory cut = composed.upgradeCut();
        assertEq(
            keccak256(abi.encode(cut)),
            keccak256(abi.encode(_expectedCut(composed))),
            "the cut must be the engine init naming this object"
        );
        // The same bytes, read back field by field.
        assertEq(cut.facetCuts.length, 0, "the bootstrap cut carries no facet cuts");
        assertEq(cut.initAddress, upgradeEngine, "the init target is the pinned engine");
        assertEq(this.decodeUpgradeInit(cut.initCalldata), address(composed), "the init names this object");

        // The inputs the engine reads at execution.
        BootstrapManifest memory served = composed.getManifest();
        assertEq(served.currentRelease, address(tableRelease), "the release whose verifier the engine installs");
        assertEq(composed.newProtocolVersion(), newVersion, "the edge lands on its genesis release's version");
        assertEq(composed.newProtocolVersion(), tableRelease.protocolVersion());
        assertEq(served.upgradeTimestamp, PLAN_UPGRADE_TIMESTAMP, "the schedule is the manifest's");

        vm.expectCall(
            address(delegateComposer),
            abi.encodeCall(
                IL2DelegateCalldataComposer.composeDelegateCalldata,
                (ICTMRelease(address(tableRelease)), address(bridgehub), chainId)
            )
        );
        L2CanonicalTransaction memory transaction = composed.l2UpgradeTx(chainId);
        assertEq(
            keccak256(abi.encode(transaction)),
            keccak256(abi.encode(_expectedL2Tx(plan, DELEGATE_CALLDATA))),
            "the served transaction is the composition of the FINAL plan"
        );
        _assertComposedL2Tx(transaction, plan, DELEGATE_CALLDATA);
    }

    /// @dev Field-level read of a composed L2 transaction against the plan it was built from.
    function _assertComposedL2Tx(
        L2CanonicalTransaction memory _transaction,
        L2UpgradePlan memory _plan,
        bytes memory _expectedDelegateCalldata
    ) internal {
        assertEq(_transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE, "the VM's upgrade tx type");
        assertEq(_transaction.from, uint256(uint160(L2_FORCE_DEPLOYER_ADDR)));
        assertEq(_transaction.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)));
        assertEq(_transaction.gasLimit, UPGRADE_TX_MAX_GAS_LIMIT);
        assertEq(_transaction.gasPerPubdataByteLimit, REQUIRED_L2_GAS_PRICE_PER_PUBDATA);
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(newVersion));
        assertEq(_transaction.nonce, minor, "the nonce is the new minor version");
        assertEq(_transaction.factoryDeps, _plan.factoryDepHashes, "every plan dependency rides the tx");
        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments,
            address delegateTo,
            bytes memory delegateCalldata
        ) = this.decodeUniversalCall(_transaction.data);
        assertEq(abi.encode(deployments), abi.encode(_plan.deployments), "the tx deploys the FINAL plan");
        assertEq(delegateTo, _plan.delegateTo, "the tx delegates to the plan's target");
        assertEq(delegateCalldata, _expectedDelegateCalldata, "the delegate calldata");
    }

    /// @dev `migrate()` commits exactly the composed cut: the CTM's committed hash for the
    ///      departing version is `keccak256(abi.encode(upgradeCut()))`, and chains crossing the
    ///      edge hand those bytes to the legacy cut-taking entrypoint.
    function test_migrate_commitsTheComposedCutHash() public {
        CTMRelease tableRelease = _deployTableRelease();
        RegistryBootstrapMigration composed = _deployAndAuthorize(_tableManifest(tableRelease));
        L2PlanFixtures.publish(bytecodesSupplier, _tableCodes());
        uint256 oldVersion = chainContractAddress.protocolVersion();
        bytes32 expectedHash = keccak256(abi.encode(_expectedCut(composed)));

        vm.expectEmit(true, true, false, false, address(chainContractAddress));
        emit IChainTypeManager.NewUpgradeCutHash(oldVersion, expectedHash);
        composed.migrate();

        assertEq(chainContractAddress.upgradeCutHash(oldVersion), expectedHash, "the CTM commits the composed cut");
        assertEq(
            chainContractAddress.upgradeCutHash(oldVersion),
            keccak256(abi.encode(composed.upgradeCut())),
            "the served cut is the committed one"
        );
        assertEq(chainContractAddress.currentRelease(), address(tableRelease), "the table release is pinned");
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        _mockMigrationsUnpaused();
        composed.validateApplied();
    }

    /// @dev What the delegate is called WITH is defined by the pinned composer, asked with the
    ///      genesis release and the CTM's Bridgehub: the composed data decodes to
    ///      `forceDeployAndUpgradeUniversal(deployments, delegateTo, <composer output>)`.
    function test_composedL2Tx_callsTheDelegateWithThePinnedComposersCalldata() public {
        RegistryBootstrapMigration authored = new RegistryBootstrapMigration(_manifestWithL2Plan(_authoredPlan()));
        L2UpgradePlan memory plan = authored.l2Plan();

        vm.expectCall(
            address(delegateComposer),
            abi.encodeCall(
                IL2DelegateCalldataComposer.composeDelegateCalldata,
                (ICTMRelease(address(genesisRelease)), address(bridgehub), chainId)
            )
        );
        L2CanonicalTransaction memory transaction = authored.l2UpgradeTx(chainId);

        (
            IComplexUpgrader.UniversalContractUpgradeInfo[] memory deployments,
            address delegateTo,
            bytes memory delegateCalldata
        ) = this.decodeUniversalCall(transaction.data);
        assertEq(deployments.length, 1, "the delegate's own deployment");
        assertEq(abi.encode(deployments), abi.encode(plan.deployments));
        assertEq(delegateTo, plan.delegateTo);
        assertEq(delegateCalldata, DELEGATE_CALLDATA, "the delegate is called with what the composer composed");
        assertEq(keccak256(abi.encode(transaction)), keccak256(abi.encode(_expectedL2Tx(plan, DELEGATE_CALLDATA))));
    }

    /// @dev A zero composer is a legal plan with a delegate target: the delegate is called with
    ///      EMPTY calldata, there is no composer pin to hold, and the edge commits.
    function test_composedL2Tx_withoutComposerCallsTheDelegateWithEmptyCalldata() public {
        AuthoredL2Plan memory plan = _authoredPlan();
        plan.delegateComposer = address(0);
        RegistryBootstrapMigration uncomposed = _deployAndAuthorize(_manifestWithL2Plan(plan));
        L2UpgradePlan memory served = uncomposed.l2Plan();
        assertEq(served.delegateComposer, address(0), "no composer is served as zero");

        L2CanonicalTransaction memory transaction = uncomposed.l2UpgradeTx(chainId);
        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE, "the plan still has an L2 side");
        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (served.deployments, served.delegateTo, "")
            ),
            "without a composer the delegate is called with empty calldata"
        );

        uint256 oldVersion = chainContractAddress.protocolVersion();
        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(DELEGATE_CODE));
        uncomposed.migrate();
        assertEq(chainContractAddress.upgradeCutHash(oldVersion), keccak256(abi.encode(uncomposed.upgradeCut())));
    }

    // ─────────────────────────────── final L2 plan ───────────────────────────────

    /// @dev The FINAL plan is the genesis release's table-derived set followed by the authored
    ///      extras; the authored delegate leg and dependencies ride through unchanged.
    function test_l2Plan_isTheReleaseTableDerivedSetFollowedByTheAuthoredExtras() public {
        CTMRelease tableRelease = _deployTableRelease();
        BootstrapManifest memory manifest = _tableManifest(tableRelease);
        RegistryBootstrapMigration composed = new RegistryBootstrapMigration(manifest);

        L2UpgradePlan memory plan = composed.l2Plan();
        assertEq(plan.deployments.length, 2, "derived row + authored delegate");
        // The derived row: the VM's flavor (the release's DiamondInit was built with true), the
        // member's fixed address, the table's descriptor verbatim.
        assertTrue(
            plan.deployments[0].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
            "table rows derive the VM's system-proxy upgrade"
        );
        assertEq(plan.deployments[0].newAddress, L2_BRIDGEHUB_ADDR, "table rows land on the member's fixed address");
        assertEq(
            plan.deployments[0].deployedBytecodeInfo,
            L2PlanFixtures.systemProxyRow(BRIDGEHUB_IMPL_CODE, SYSTEM_PROXY_CODE)
        );
        // The authored delegate follows, constructed from its bytecode info.
        assertEq(
            abi.encode(plan.deployments[1]),
            abi.encode(L2PlanFixtures.unsafeDeployment(DELEGATE_CODE)),
            "the delegate's Unsafe deployment is appended after the derived set"
        );
        assertEq(plan.delegateTo, plan.deployments[1].newAddress, "the delegate target is its derived address");
        assertEq(plan.delegateComposer, address(delegateComposer), "the pinned composer is served");
        assertEq(
            plan.factoryDepHashes,
            L2PlanFixtures.factoryDepHashes(
                L2PlanFixtures.codes(BRIDGEHUB_IMPL_CODE, SYSTEM_PROXY_CODE, DELEGATE_CODE)
            ),
            "the dependencies are constructed: the row's implementation and shell, then the delegate"
        );
    }

    /// @dev The fixture's default: an empty genesis table and nothing authored is an L1-only
    ///      edge — the served plan is empty and the composed cut carries the all-zero L2
    ///      transaction `BaseZkSyncUpgrade` skips.
    function test_l2Plan_emptyTableAndNoExtrasComposeAnL1OnlyEdge() public view {
        L2UpgradePlan memory plan = migration.l2Plan();
        assertEq(plan.deployments.length, 0, "nothing derived, nothing authored");
        assertEq(plan.delegateTo, address(0));
        assertEq(plan.delegateComposer, address(0));
        assertEq(plan.factoryDepHashes.length, 0);

        L2CanonicalTransaction memory transaction = migration.l2UpgradeTx(chainId);
        assertEq(transaction.txType, 0, "no L2 side composes no L2 transaction");
        assertEq(
            keccak256(abi.encode(transaction)),
            keccak256(abi.encode(L2CanonicalTransactionLib.emptyL2CanonicalTransaction())),
            "the all-zero transaction, exactly"
        );
        assertEq(
            keccak256(abi.encode(migration.upgradeCut())),
            keccak256(abi.encode(_expectedCut(migration))),
            "an L1-only edge commits the same shape of cut: the engine init naming this object"
        );
    }

    /// @dev An empty table with an authored delegate: the final plan IS the extra, and the edge
    ///      has an L2 side (the shape the publication gate below runs on).
    function test_l2Plan_emptyTableWithAuthoredDelegateIsTheExtraAlone() public {
        RegistryBootstrapMigration authored = new RegistryBootstrapMigration(_manifestWithL2Plan(_authoredPlan()));

        L2UpgradePlan memory plan = authored.l2Plan();
        assertEq(plan.deployments.length, 1, "the delegate's own deployment and nothing else");
        assertTrue(
            plan.deployments[0].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment
        );
        assertEq(
            plan.deployments[0].newAddress,
            L2GenesisForceDeploymentsHelper.generateRandomAddress(plan.deployments[0].deployedBytecodeInfo),
            "the extra sits at its bytecode-derived address"
        );
        assertEq(plan.delegateTo, plan.deployments[0].newAddress);
        assertEq(plan.factoryDepHashes.length, 1);
        assertEq(plan.factoryDepHashes[0], L2PlanFixtures.factoryDepHash(DELEGATE_CODE));
        assertEq(
            authored.l2UpgradeTx(chainId).txType,
            ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE,
            "an authored delegate alone gives the edge an L2 side"
        );
    }

    // ─────────────────────────── factory dependency publication ───────────────────────────

    /// @dev The composed L2 transaction fails on every chain unless the plan's factory
    ///      dependencies are on the CTM's supplier, so the edge refuses to commit until they are —
    ///      and commits, unchanged, once they are published.
    function test_migrate_requiresPlanFactoryDepsPublished() public {
        RegistryBootstrapMigration gated = _deployAndAuthorize(_manifestWithL2Plan(_authoredPlan()));
        uint256 oldVersion = chainContractAddress.protocolVersion();
        assertEq(chainContractAddress.L1_BYTECODES_SUPPLIER(), address(bytecodesSupplier));
        assertEq(bytecodesSupplier.evmPublishingBlock(keccak256(DELEGATE_CODE)), 0, "fixture: not yet published");
        assertEq(gated.l2Plan().factoryDepHashes[0], uint256(keccak256(DELEGATE_CODE)), "the gated dependency");
        bytes32 composedCutHash = keccak256(abi.encode(gated.upgradeCut()));

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(DELEGATE_CODE)));
        gated.migrate();
        assertFalse(gated.executed(), "a refused edge must stay unspent");
        assertEq(chainContractAddress.protocolVersion(), oldVersion, "a refused edge must not move the CTM");
        assertEq(chainContractAddress.upgradeCutHash(oldVersion), bytes32(0), "a refused edge commits no cut");

        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(DELEGATE_CODE));

        gated.migrate();
        assertTrue(gated.executed(), "the same edge applies once the bytecode is published");
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.upgradeCutHash(oldVersion), composedCutHash, "publication changes no bytes");
        _mockMigrationsUnpaused();
        gated.validateApplied();
    }

    // ─────────────────────────── post-state verification ───────────────────────────

    /// @dev The completion check runs as its own call after stage 2: before the edge it must fail
    ///      loudly, so an incorrectly sequenced bundle cannot report success on an unapplied bootstrap.
    function test_revertWhen_validateAppliedBeforeMigrate() public {
        vm.expectRevert(BootstrapNotYetExecuted.selector);
        migration.validateApplied();
    }

    /// @dev Completion includes the operational restrictions being lifted: the stage-0 pause the
    ///      edge ran under must have been released, or stage 2 does not pass.
    function test_revertWhen_validateAppliedWhileMigrationsStillPaused() public {
        _handOverAuthority();
        migration.migrate();

        vm.expectRevert(MigrationPaused.selector);
        migration.validateApplied();

        _mockMigrationsUnpaused();
        migration.validateApplied();
    }

    function test_validateAppliedRequiresCoordinatorToNameTheBootstrappedExecutor() public {
        _handOverAuthority();
        migration.migrate();
        _mockMigrationsUnpaused();
        CTMUpgradeExecutor replacement = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            address(coordinator)
        );
        vm.prank(governor);
        coordinator.setCTMExecutor(replacement);

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(coordinator),
                address(ctmExecutor),
                address(replacement)
            )
        );
        migration.validateApplied();
        assertTrue(migration.executed(), "failed completion does not undo the migration");
        assertEq(chainContractAddress.owner(), address(ctmExecutor));
        assertEq(ctmProxyAdmin.owner(), address(ctmExecutor));
        assertEq(address(coordinator.ctmExecutor()), address(replacement));

        vm.prank(governor);
        coordinator.setCTMExecutor(ctmExecutor);
        migration.validateApplied();
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor));
    }

    /// @dev A `transferOwnership` appended to the bundle beside the derived calls is invisible to
    ///      the owner checks (`owner()` does not move until the nominee accepts) and lets the
    ///      nominee take the domain the moment the gate has passed. The gate refuses a pending
    ///      nomination on every `Ownable2Step` authority the edge lands on or drives, and reopens
    ///      once it is withdrawn. The `ProxyAdmin`s are plain `Ownable` and cannot be nominated.
    function test_revertWhen_validateAppliedWithANominationPendingOnAnAuthority() public {
        _handOverAuthority();
        migration.migrate();
        _mockMigrationsUnpaused();
        migration.validateApplied();
        address attacker = makeAddr("attacker");

        // The three executors are governance-owned: the nomination is governance's own call.
        Ownable2Step[3] memory governed = [
            Ownable2Step(address(ctmExecutor)),
            Ownable2Step(address(coordinator)),
            Ownable2Step(address(coreExecutor))
        ];
        for (uint256 i = 0; i < governed.length; ++i) {
            vm.prank(governor);
            governed[i].transferOwnership(attacker);
            assertEq(governed[i].owner(), governor, "the owner has not moved, which is what hides the nomination");
            vm.expectRevert(
                abi.encodeWithSelector(BootstrapNominationPending.selector, address(governed[i]), attacker)
            );
            migration.validateApplied();

            vm.prank(governor);
            governed[i].transferOwnership(address(0));
            migration.validateApplied();
        }

        // The CTM is the executor's after the edge, so a nomination reaches it through the
        // executor's raw-call hatch — the one way an appended call could.
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (attacker))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
        assertEq(chainContractAddress.owner(), address(ctmExecutor));
        vm.expectRevert(
            abi.encodeWithSelector(BootstrapNominationPending.selector, address(chainContractAddress), attacker)
        );
        migration.validateApplied();

        calls[0].data = abi.encodeCall(Ownable2Step.transferOwnership, (address(0)));
        vm.prank(governor);
        ctmExecutor.forward(calls);
        migration.validateApplied();

        // The notifier is the executor's too, so the same hatch reaches it.
        calls[0] = Call({
            target: address(notifierProxy),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (attacker))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
        vm.expectRevert(abi.encodeWithSelector(BootstrapNominationPending.selector, address(notifierProxy), attacker));
        migration.validateApplied();

        calls[0].data = abi.encodeCall(Ownable2Step.transferOwnership, (address(0)));
        vm.prank(governor);
        ctmExecutor.forward(calls);
        migration.validateApplied();
    }

    // ─────────────────────────── timer gating ───────────────────────────

    /// @dev The timer proves stage 0 ran: an edge whose timer was never started must not
    ///      execute, regardless of authority.
    function test_revertWhen_timerNeverStarted() public {
        GovernanceUpgradeTimer unstarted = new GovernanceUpgradeTimer(0, 0, governor, governor);
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeTimer = address(unstarted);
        RegistryBootstrapMigration gated = new RegistryBootstrapMigration(manifest);

        vm.prank(governor);
        chainContractAddress.transferOwnership(address(gated));
        ctmProxyAdmin.transferOwnership(address(gated));

        vm.expectRevert(TimerNotStarted.selector);
        gated.migrate();
    }

    function test_revertWhen_timerDeadlineNotYetPassed() public {
        GovernanceUpgradeTimer pending = new GovernanceUpgradeTimer(1000, 0, governor, governor);
        vm.prank(governor);
        pending.startTimer();
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeTimer = address(pending);
        RegistryBootstrapMigration gated = new RegistryBootstrapMigration(manifest);

        vm.prank(governor);
        chainContractAddress.transferOwnership(address(gated));
        ctmProxyAdmin.transferOwnership(address(gated));

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
            ctmProxyAdmin,
            address(coordinator)
        );
        BootstrapManifest memory manifest = _manifest();
        manifest.ctmExecutor = address(foreignExecutor);

        RegistryBootstrapMigration mismatched = new RegistryBootstrapMigration(manifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(mismatched));
        ctmProxyAdmin.transferOwnership(address(mismatched));

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
            address(coordinator)
        );
        BootstrapManifest memory manifest = _manifest();
        manifest.ctmExecutor = address(foreignExecutor);

        RegistryBootstrapMigration mismatched = new RegistryBootstrapMigration(manifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(mismatched));
        ctmProxyAdmin.transferOwnership(address(mismatched));

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(foreignExecutor),
                address(ctmProxyAdmin),
                address(foreignProxyAdmin)
            )
        );
        mismatched.migrate();
    }

    /// @dev The executor's OWNERSHIP is storage, so the reviewed deployment does not settle it.
    ///      An executor whose ownership moved after this manifest was reviewed would otherwise
    ///      pass every other check and then receive the whole CTM domain on behalf of its new
    ///      owner.
    function test_revertWhen_ctmExecutorIsOwnedBySomeoneElse() public {
        address stranger = makeAddr("stranger");
        vm.prank(governor);
        ctmExecutor.transferOwnership(stranger);
        vm.prank(stranger);
        ctmExecutor.acceptOwnership();
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapExecutorOwnerMismatch.selector, address(ctmExecutor), governor, stranger)
        );
        migration.migrate();
        assertFalse(migration.executed(), "a refused edge must stay unspent");
    }

    /// @dev The same hole one step removed: a nomination outstanding at handover time lets the
    ///      nominee claim the domain immediately after `migrate()`.
    function test_revertWhen_ctmExecutorHasAPendingOwnershipTransfer() public {
        address nominee = makeAddr("nominee");
        vm.prank(governor);
        ctmExecutor.transferOwnership(nominee);
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(BootstrapNominationPending.selector, address(ctmExecutor), nominee));
        migration.migrate();
    }

    /// @dev The coordinator the CTM executor answers to is storage too (governance may replace it
    ///      between operations), and it is the only address that will drive the executor's
    ///      lifecycle callbacks.
    function test_revertWhen_ctmExecutorAnswersToAnotherCoordinator() public {
        EcosystemUpgradeExecutor foreignCoordinator = new EcosystemUpgradeExecutor(governor, coreExecutor);
        CTMUpgradeExecutor redirected = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            address(foreignCoordinator)
        );
        BootstrapManifest memory manifest = _manifest();
        manifest.ctmExecutor = address(redirected);

        RegistryBootstrapMigration mismatched = new RegistryBootstrapMigration(manifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(mismatched));
        ctmProxyAdmin.transferOwnership(address(mismatched));

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(redirected),
                address(coordinator),
                address(foreignCoordinator)
            )
        );
        mismatched.migrate();
    }

    /// @dev A refused edge leaves NOTHING behind. `migrate()` accepts CTM ownership before it
    ///      validates, so the check has to unwind that too: the CTM must still be owned by
    ///      governance, the object unspent, and a corrected edge must still be runnable.
    function test_refusedOwnershipCheckRollsBackTheWholeEdge() public {
        address stranger = makeAddr("stranger");
        vm.prank(governor);
        ctmExecutor.transferOwnership(stranger);
        vm.prank(stranger);
        ctmExecutor.acceptOwnership();
        address ownerBefore = Ownable2Step(address(chainContractAddress)).owner();
        uint256 versionBefore = chainContractAddress.protocolVersion();
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapExecutorOwnerMismatch.selector, address(ctmExecutor), governor, stranger)
        );
        migration.migrate();

        // The accept inside `migrate()` is undone with the rest of it: the CTM is still where it
        // was, merely nominated, and nothing about the edge was applied.
        assertEq(Ownable2Step(address(chainContractAddress)).owner(), ownerBefore, "CTM ownership must not move");
        assertEq(
            Ownable2Step(address(chainContractAddress)).pendingOwner(),
            address(migration),
            "the nomination stands"
        );
        assertEq(chainContractAddress.protocolVersion(), versionBefore, "no version edge was committed");
        assertFalse(migration.executed(), "a refused edge must stay unspent");

        // Ownership put back where the manifest says it belongs, the same edge now runs.
        vm.prank(stranger);
        ctmExecutor.transferOwnership(governor);
        vm.prank(governor);
        ctmExecutor.acceptOwnership();
        migration.migrate();
        assertTrue(migration.executed(), "the corrected edge must run");
        _mockMigrationsUnpaused();
        migration.validateApplied();
    }

    function test_revertWhen_executorHasNoCode() public {
        vm.etch(address(ctmExecutor), "");
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, address(ctmExecutor)));
        migration.migrate();
    }

    // ─────────────────────────── engine and composer code ───────────────────────────

    /// @dev The engine is the code the committed cut delegatecalls into on every chain: a codeless
    ///      one would make every chain's upgrade a no-op delegatecall that silently "succeeds".
    ///      Held on the execution path, so the object still constructs and serves the address.
    function test_revertWhen_upgradeEngineHasNoCode() public {
        RegistryBootstrapMigration authorized = _deployAndAuthorize(_manifest());
        uint256 oldVersion = chainContractAddress.protocolVersion();
        assertEq(authorized.upgradeCut().initAddress, upgradeEngine, "the engine is served like any other member");

        vm.etch(upgradeEngine, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, upgradeEngine));
        authorized.migrate();
        assertFalse(authorized.executed(), "a refused edge must stay unspent");
        assertEq(chainContractAddress.upgradeCutHash(oldVersion), bytes32(0), "a refused edge commits no cut");
    }

    /// @dev The composer is version-specific CODE in place of authored calldata, so when the plan
    ///      names one it is required to exist exactly like the engine.
    function test_revertWhen_delegateComposerHasNoCode() public {
        RegistryBootstrapMigration authorized = _deployAndAuthorize(_manifestWithL2Plan(_authoredPlan()));
        assertEq(
            authorized.l2Plan().delegateComposer,
            address(delegateComposer),
            "the composer is served like every other member"
        );

        vm.etch(address(delegateComposer), "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, address(delegateComposer)));
        authorized.migrate();
        assertFalse(authorized.executed(), "a refused edge must stay unspent");
    }

    // ─────────────────────────── manifest shape ───────────────────────────

    function test_revertWhen_upgradeEngineIsZero() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeEngine = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapMigration(manifest);
    }

    /// @dev Two rows for one proxy would BOTH pass the source check (they compare against the same
    ///      pre-migration implementation) and the last would silently win — so the reviewed edge
    ///      and the executed edge would differ. Same rule {CoreTransition} enforces.
    function test_migrate_runsFixedInitializeUpgradeExactlyOnce() public {
        // A second participating slot whose new implementation must reinitialize: the row
        // carries only a BOOLEAN, and the apply invokes the fixed argument-less selector
        // atomically with the swap.
        MockProxyUpgradeInitImpl initImpl = new MockProxyUpgradeInitImpl();
        TransparentUpgradeableProxy vtProxy = new TransparentUpgradeableProxy(implV31, address(ctmProxyAdmin), hex"");
        BootstrapManifest memory manifest = _manifest();
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = ProxyUpgradeRow({
            proxy: address(vtProxy),
            expectedOldImpl: implV31,
            implNew: address(initImpl),
            callInitializeUpgrade: true
        });
        RegistryBootstrapMigration withInit = new RegistryBootstrapMigration(manifest);
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(withInit));
        ctmProxyAdmin.transferOwnership(address(withInit));

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
            proxy: address(ctmDomainProxy),
            expectedOldImpl: implV31,
            implNew: implV31,
            callInitializeUpgrade: false
        });

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateProxyRow.selector, address(ctmDomainProxy)));
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_manifestCarriesAZeroRowField() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.proxyUpgrades[uint256(CTMContract.ChainTypeManager)].expectedOldImpl = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapMigration(manifest);
    }

    // ─────────────────────────── L2 plan shape ───────────────────────────
    // The same rules {CTMTransition} enforces, run against the CONSTRUCTED (derived + authored)
    // plan at construction, so an edge whose L2 leg cannot execute refuses to exist. One test per
    // rule, each on an otherwise well-formed plan so exactly that rule fires.

    function test_revertWhen_authoredDeploymentsWithoutDelegate() public {
        // Force-deployments but no delegate: `L2ComplexUpgrader` always ends with the final
        // delegatecall, so a deployments-only plan would construct here yet revert on L2 forever.
        // (No composer either, so ONLY the deployments-without-delegate rule can fire.)
        AuthoredL2Plan memory plan = _emptyL2Plan();
        plan.extraBytecodeInfos = new bytes[](1);
        plan.extraBytecodeInfos[0] = L2PlanFixtures.bytecodeInfo(DELEGATE_CODE);

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(L2PlanNeedsDelegate.selector);
        new RegistryBootstrapMigration(manifest);
    }

    /// @dev The genesis release's table decides whether the derived set is empty: against a
    ///      release with a row, an edge that authors NOTHING still needs its delegate.
    function test_revertWhen_derivedDeploymentsWithoutDelegateTarget() public {
        CTMRelease tableRelease = _deployTableRelease();
        BootstrapManifest memory manifest = _manifestWithL2Plan(_emptyL2Plan());
        manifest.currentRelease = address(tableRelease);

        vm.expectRevert(L2PlanNeedsDelegate.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_delegateComposerWithoutTarget() public {
        // Code defining calldata for a delegate call that never happens.
        AuthoredL2Plan memory plan = _emptyL2Plan();
        plan.delegateComposer = address(delegateComposer);

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(L2PlanNeedsDelegate.selector);
        new RegistryBootstrapMigration(manifest);
    }

    /// @dev A plan whose CONSTRUCTED factory deps exceed what `BaseZkSyncUpgrade` accepts must be
    ///      rejected at pin time: otherwise the edge commits and every per-chain upgrade then
    ///      reverts. The delegate plus `MAX_NEW_FACTORY_DEPS` distinct extras is one past the cap.
    function test_revertWhen_factoryDepsExceedTheCap() public {
        AuthoredL2Plan memory plan = _authoredPlan();
        plan.extraBytecodeInfos = new bytes[](MAX_NEW_FACTORY_DEPS);
        for (uint256 i = 0; i < plan.extraBytecodeInfos.length; ++i) {
            plan.extraBytecodeInfos[i] = L2PlanFixtures.bytecodeInfo(abi.encodePacked(bytes2(0xee00), uint8(i)));
        }

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(
            abi.encodeWithSelector(L2PlanTooManyFactoryDeps.selector, MAX_NEW_FACTORY_DEPS + 1, MAX_NEW_FACTORY_DEPS)
        );
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_delegateBytecodeInfoIsMalformed() public {
        // Not a canonical (blake, length, keccak) tuple: no address can be derived from it.
        AuthoredL2Plan memory plan = _authoredPlan();
        plan.delegateBytecodeInfo = hex"aa01";

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeInfoLength.selector, 2, BYTECODE_INFO_LENGTH));
        new RegistryBootstrapMigration(manifest);
    }

    // ─────────────────────────── version and rows ───────────────────────────

    function test_revertWhen_departingVersionIsNotTheExpectedOne() public {
        // A migration pinned for one ecosystem must refuse a differently-versioned one.
        RegistryBootstrapMigration staleMigration = new RegistryBootstrapMigration(
            _manifestWithExpectedVersion(chainContractAddress.protocolVersion() + 1)
        );
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(staleMigration));
        ctmProxyAdmin.transferOwnership(address(staleMigration));

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
        ctmProxyAdmin.upgrade(ITransparentUpgradeableProxy(address(ctmDomainProxy)), implUnknown);
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implV31, implUnknown)
        );
        migration.migrate();
        assertFalse(migration.executed(), "a refused edge must stay unspent");
    }

    /// @dev A row whose proxy already sits at `implNew` was applied before the edge: the source
    ///      check tolerates it, `applyRows` skips it (no re-apply, no event), and the post-state
    ///      check holds. Both of the edge's rows are pre-applied here.
    function test_migrate_acceptsARowAlreadyAtItsNewImplementation() public {
        ctmProxyAdmin.upgrade(ITransparentUpgradeableProxy(address(ctmDomainProxy)), implV32);
        ctmProxyAdmin.upgrade(ITransparentUpgradeableProxy(address(notifierProxy)), notifierImplNew);
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
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implV32);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the edge must otherwise complete");
        _mockMigrationsUnpaused();
        migration.validateApplied();
    }

    // ─────────────────────────── the core side of the handover ───────────────────────────

    /// @dev The ecosystem `ProxyAdmin` is handed to the core executor earlier in stage 1; the edge
    ///      refuses unless that handover happened, which reverts the handover with it.
    function test_revertWhen_ecosystemProxyAdminNotHandedToTheCoreExecutor() public {
        _forwardFromCoreExecutor(
            address(ecosystemProxyAdmin),
            abi.encodeCall(Ownable.transferOwnership, (address(this)))
        );
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, address(ecosystemProxyAdmin), address(this))
        );
        migration.migrate();
        assertFalse(migration.executed(), "a refused edge must stay unspent");
    }

    function test_revertWhen_coreExecutorIsOwnedBySomeoneElse() public {
        address stranger = makeAddr("stranger");
        vm.prank(governor);
        coreExecutor.transferOwnership(stranger);
        vm.prank(stranger);
        coreExecutor.acceptOwnership();
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapExecutorOwnerMismatch.selector, address(coreExecutor), governor, stranger)
        );
        migration.migrate();
    }

    function test_revertWhen_coreExecutorHasAPendingOwnershipTransfer() public {
        address nominee = makeAddr("nominee");
        vm.prank(governor);
        coreExecutor.transferOwnership(nominee);
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(BootstrapNominationPending.selector, address(coreExecutor), nominee));
        migration.migrate();
    }

    function test_revertWhen_coreExecutorAnswersToAnotherCoordinator() public {
        address other = makeAddr("otherCoordinator");
        vm.prank(governor);
        coreExecutor.setCoordinator(other);
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(coreExecutor),
                address(coordinator),
                other
            )
        );
        migration.migrate();
    }

    /// @dev A core executor answering to the coordinator is not enough: the coordinator must name
    ///      it as its `CORE_EXECUTOR`, or its stages would drive another one.
    function test_revertWhen_theCoordinatorNamesAnotherCoreExecutor() public {
        ProxyAdmin otherAdmin = new ProxyAdmin();
        CoreUpgradeExecutor otherCore = new CoreUpgradeExecutor(governor, otherAdmin);
        otherAdmin.transferOwnership(address(otherCore));
        vm.prank(governor);
        otherCore.setCoordinator(address(coordinator));
        BootstrapManifest memory manifest = _manifest();
        manifest.coreExecutor = address(otherCore);
        RegistryBootstrapMigration mismatched = _deployAndAuthorize(manifest);

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(coordinator),
                address(otherCore),
                address(coreExecutor)
            )
        );
        mismatched.migrate();
    }

    function test_revertWhen_theCoordinatorIsNotBoundToTheCtmExecutor() public {
        CTMUpgradeExecutor replacement = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            address(coordinator)
        );
        vm.prank(governor);
        coordinator.setCTMExecutor(replacement);
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(coordinator),
                address(ctmExecutor),
                address(replacement)
            )
        );
        migration.migrate();
    }

    function test_revertWhen_coordinatorIsOwnedBySomeoneElse() public {
        address stranger = makeAddr("stranger");
        vm.prank(governor);
        coordinator.transferOwnership(stranger);
        vm.prank(stranger);
        coordinator.acceptOwnership();
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapExecutorOwnerMismatch.selector, address(coordinator), governor, stranger)
        );
        migration.migrate();
    }

    function test_revertWhen_coordinatorHasAPendingOwnershipTransfer() public {
        address nominee = makeAddr("nominee");
        vm.prank(governor);
        coordinator.transferOwnership(nominee);
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(BootstrapNominationPending.selector, address(coordinator), nominee));
        migration.migrate();
    }

    /// @dev Completion checks owner IDENTITY, not only the absence of a nomination: an executor
    ///      whose ownership already moved fails the gate.
    function test_revertWhen_validateAppliedAfterAnExecutorChangedOwner() public {
        _handOverAuthority();
        migration.migrate();
        _mockMigrationsUnpaused();
        migration.validateApplied();
        address stranger = makeAddr("stranger");

        Ownable2Step[3] memory governed = [
            Ownable2Step(address(ctmExecutor)),
            Ownable2Step(address(coreExecutor)),
            Ownable2Step(address(coordinator))
        ];
        for (uint256 i = 0; i < governed.length; ++i) {
            vm.prank(governor);
            governed[i].transferOwnership(stranger);
            vm.prank(stranger);
            governed[i].acceptOwnership();
            vm.expectRevert(
                abi.encodeWithSelector(
                    BootstrapExecutorOwnerMismatch.selector,
                    address(governed[i]),
                    governor,
                    stranger
                )
            );
            migration.validateApplied();

            vm.prank(stranger);
            governed[i].transferOwnership(governor);
            vm.prank(governor);
            governed[i].acceptOwnership();
            migration.validateApplied();
        }
    }

    /// @dev ... and the core side's authority and binding.
    function test_revertWhen_validateAppliedAfterTheCoreSideMoved() public {
        _handOverAuthority();
        migration.migrate();
        _mockMigrationsUnpaused();
        migration.validateApplied();

        vm.prank(governor);
        coreExecutor.setCoordinator(address(0));
        vm.expectRevert(
            abi.encodeWithSelector(
                BootstrapExecutorNotBound.selector,
                address(coreExecutor),
                address(coordinator),
                address(0)
            )
        );
        migration.validateApplied();
        vm.prank(governor);
        coreExecutor.setCoordinator(address(coordinator));

        address stranger = makeAddr("stranger");
        _forwardFromCoreExecutor(address(ecosystemProxyAdmin), abi.encodeCall(Ownable.transferOwnership, (stranger)));
        vm.expectRevert(
            abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, address(ecosystemProxyAdmin), stranger)
        );
        migration.validateApplied();
    }

    /// @dev Governance's raw call through the core executor, which owns the ecosystem admin.
    function _forwardFromCoreExecutor(address _target, bytes memory _data) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: _target, value: 0, data: _data});
        vm.prank(governor);
        coreExecutor.forward(calls);
    }

    // ─────────────────────────── the ServerNotifier handover precondition ───────────────────────────

    function test_revertWhen_manifestHasNoServerNotifierRow() public {
        BootstrapManifest memory manifest = _manifest();
        delete manifest.proxyUpgrades[uint256(CTMContract.ServerNotifier)];

        vm.expectRevert(BootstrapServerNotifierRowMissing.selector);
        new RegistryBootstrapMigration(manifest);
    }

    /// @dev Nothing of the handover happened: the ChainAdmin still owns the notifier. Refused even
    ///      though the ChainAdmin already put the new implementation in place itself — the edge is
    ///      about authority, not the implementation.
    function test_revertWhen_notifierNotHandedOver_evenIfItsImplementationIsAlreadyNew() public {
        (BootstrapManifest memory manifest, TransparentUpgradeableProxy fresh) = _manifestWithFreshNotifier();
        vm.prank(chainAdmin);
        notifierAdmin.upgrade(ITransparentUpgradeableProxy(address(fresh)), notifierImplNew);
        RegistryBootstrapMigration gated = _deployAndAuthorize(manifest);

        vm.expectRevert(abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, address(fresh), chainAdmin));
        gated.migrate();
        assertFalse(gated.executed(), "a refused edge must stay unspent");
        assertEq(chainContractAddress.protocolVersion(), 0, "a refused edge must not move the CTM");
    }

    /// @dev The ChainAdmin did its half — the proxy moved, the executor is nominated — but
    ///      governance has not accepted yet: the notifier is still the ChainAdmin's.
    function test_revertWhen_notifierNominatedButNotAccepted() public {
        (BootstrapManifest memory manifest, TransparentUpgradeableProxy fresh) = _manifestWithFreshNotifier();
        _moveNotifierUnderTheCtmProxyAdmin(fresh);
        _nominateExecutorForNotifier(fresh);
        RegistryBootstrapMigration gated = _deployAndAuthorize(manifest);

        vm.expectRevert(abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, address(fresh), chainAdmin));
        gated.migrate();

        _acceptNotifierThroughTheExecutor(fresh);
        gated.migrate();
        assertEq(Ownable2Step(address(fresh)).owner(), address(ctmExecutor));
        assertEq(_liveImpl(ctmProxyAdmin, fresh), notifierImplNew, "the row applies once the handover is done");
    }

    /// @dev Ownership handed over, but the proxy is still under its old ProxyAdmin. A transparent
    ///      proxy answers `admin()` only to its own admin, so the check reverts without data.
    function test_revertWhen_notifierStillUnderItsOldProxyAdmin() public {
        (BootstrapManifest memory manifest, TransparentUpgradeableProxy fresh) = _manifestWithFreshNotifier();
        _nominateExecutorForNotifier(fresh);
        _acceptNotifierThroughTheExecutor(fresh);
        RegistryBootstrapMigration gated = _deployAndAuthorize(manifest);

        vm.expectRevert(bytes(""));
        gated.migrate();
        assertFalse(gated.executed(), "a refused edge must stay unspent");

        _moveNotifierUnderTheCtmProxyAdmin(fresh);
        gated.migrate();
        assertTrue(gated.executed());
    }

    /// @dev A nomination the executor itself issued would let its nominee take the notifier right
    ///      after the edge.
    function test_revertWhen_notifierHasAPendingNomination() public {
        address nominee = makeAddr("nominee");
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(notifierProxy),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (nominee))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(BootstrapNominationPending.selector, address(notifierProxy), nominee));
        migration.migrate();
    }

    /// @dev The manifest's notifier must be the one the CTM serves.
    function test_revertWhen_notifierIsNotTheCtms() public {
        address other = makeAddr("otherNotifier");
        vm.prank(governor);
        chainContractAddress.setServerNotifier(other);
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapServerNotifierNotBound.selector, address(notifierProxy), other)
        );
        migration.migrate();
    }

    /// @dev ... and it must serve this CTM.
    function test_revertWhen_notifierServesAnotherCtm() public {
        address otherCtm = makeAddr("otherCtm");
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(notifierProxy),
            value: 0,
            data: abi.encodeCall(ServerNotifier.setChainTypeManager, (IChainTypeManager(otherCtm)))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
        _handOverAuthority();

        vm.expectRevert(
            abi.encodeWithSelector(BootstrapServerNotifierNotBound.selector, address(chainContractAddress), otherCtm)
        );
        migration.migrate();
    }

    // ─────────────────────────── completion check ───────────────────────────

    /// @dev Completion does not pin the CTM-domain proxies to the rows `migrate()` applied:
    ///      governance re-patching one through the executor afterwards still completes.
    function test_validateApplied_passesAfterAnInfrastructureRepatch() public {
        _handOverAuthority();
        migration.migrate();
        _mockMigrationsUnpaused();

        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(ctmProxyAdmin),
            value: 0,
            data: abi.encodeCall(
                ProxyAdmin.upgrade,
                (ITransparentUpgradeableProxy(address(ctmDomainProxy)), implUnknown)
            )
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implUnknown, "fixture: the row's proxy moved on");

        migration.validateApplied();
    }

    /// @dev The timer is re-checked at completion: an extension made after `migrate()` defers the
    ///      completion check until it passes.
    function test_revertWhen_validateAppliedBeforeAnExtendedTimerDeadline() public {
        GovernanceUpgradeTimer extendable = new GovernanceUpgradeTimer(0, 100, governor, governor);
        vm.prank(governor);
        extendable.startTimer();
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeTimer = address(extendable);
        RegistryBootstrapMigration timed = _deployAndAuthorize(manifest);
        timed.migrate();
        _mockMigrationsUnpaused();
        timed.validateApplied();

        vm.prank(governor);
        extendable.changeDeadline(block.timestamp + 50);
        vm.expectRevert(DeadlineNotYetPassed.selector);
        timed.validateApplied();

        vm.warp(block.timestamp + 50);
        timed.validateApplied();
    }

    /// @dev The notifier must stay the CTM executor's: the gate refuses once its ownership left.
    function test_revertWhen_validateAppliedAfterTheNotifierLeftTheExecutor() public {
        _handOverAuthority();
        migration.migrate();
        _mockMigrationsUnpaused();
        address stranger = makeAddr("stranger");
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(notifierProxy),
            value: 0,
            data: abi.encodeCall(Ownable2Step.transferOwnership, (stranger))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
        vm.prank(stranger);
        Ownable2Step(address(notifierProxy)).acceptOwnership();

        vm.expectRevert(abi.encodeWithSelector(BootstrapAuthorityNotHeld.selector, address(notifierProxy), stranger));
        migration.validateApplied();
    }

    function test_revertWhen_rowImplementationHasNoCode() public {
        // A row pointing a proxy at an address with no code would brick it; `ProxyAdmin` refuses
        // it too, but the edge has to say so before it spends itself.
        vm.etch(implV32, "");
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, implV32));
        migration.migrate();
    }

    function test_revertWhen_releaseHasNoCode() public {
        // The anchor this edge installs is READ from the release's live code, so a codeless
        // release would anchor the empty-code hash and accept nothing afterwards. Refused before
        // the migration spends itself.
        vm.etch(address(genesisRelease), "");
        _handOverAuthority();

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, address(genesisRelease)));
        migration.migrate();
    }

    function test_manifestHashCommitsToTheWholeEdge() public view {
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

    // ─────────────────────────── selector-less release member ───────────────────────────

    /// @dev The bootstrap engine reinstalls the release's facets with one `Add` per row, so a
    ///      selector-less facet would make every chain's crossing revert. The migration refuses the
    ///      release before it spends itself, so the engine never sees one.
    function test_revertWhen_releaseHasASelectorlessFacet() public {
        address emptyFacet = address(new MockSelfDescribingFacet(new bytes4[](0)));
        facetCuts[0].facet = emptyFacet;
        BootstrapManifest memory manifest = _manifest();
        manifest.currentRelease = address(_deployRelease(new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)));
        RegistryBootstrapMigration authorized = _deployAndAuthorize(manifest);

        vm.expectRevert(abi.encodeWithSelector(RegistryEmptySelectors.selector, emptyFacet));
        authorized.migrate();
        assertFalse(authorized.executed(), "a refused edge must stay unspent");
        assertEq(chainContractAddress.protocolVersion(), manifest.expectedProtocolVersion, "the CTM did not move");
    }

    // ─────────────────── edge rules (shared with CTMTransition) ───────────────────

    /// @dev A genesis release at `_version` over the fixture's members and `_l2BytecodeInfos`.
    function _releaseAtVersion(
        uint256 _version,
        bytes[] memory _l2BytecodeInfos
    ) internal returns (CTMRelease release) {
        uint256 fixtureVersion = newVersion;
        newVersion = _version;
        release = _deployRelease(_l2BytecodeInfos);
        newVersion = fixtureVersion;
    }

    function _emptyTable() internal pure returns (bytes[] memory) {
        return new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
    }

    function test_revertWhen_bootstrapDeadlineIsZero() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.oldProtocolVersionDeadline = 0;

        vm.expectRevert(TransitionDeadlineZero.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_bootstrapDeadlineIsBeforeTheUpgradeTimestamp() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeTimestamp = PLAN_UPGRADE_TIMESTAMP;
        manifest.oldProtocolVersionDeadline = PLAN_UPGRADE_TIMESTAMP - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                TransitionDeadlineBeforeUpgrade.selector,
                PLAN_UPGRADE_TIMESTAMP - 1,
                PLAN_UPGRADE_TIMESTAMP
            )
        );
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_bootstrapDoesNotMoveTheVersionForward() public {
        BootstrapManifest memory manifest = _manifestWithExpectedVersion(newVersion);

        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector, newVersion, newVersion));
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_bootstrapDepartsFromANonzeroMajor() public {
        BootstrapManifest memory manifest = _manifestWithExpectedVersion(SemVer.packSemVer(1, 0, 0));
        manifest.currentRelease = address(_releaseAtVersion(SemVer.packSemVer(1, 1, 0), _emptyTable()));

        vm.expectRevert(PreviousProtocolMajorVersionNotZero.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_bootstrapTargetsANonzeroMajor() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.currentRelease = address(_releaseAtVersion(SemVer.packSemVer(1, 0, 0), _emptyTable()));

        vm.expectRevert(NewProtocolMajorVersionNotZero.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_bootstrapMinorDeltaIsTooBig() public {
        // The fixture CTM departs from 0.0.0.
        uint32 tooFar = uint32(MAX_ALLOWED_MINOR_VERSION_DELTA) + 1;
        BootstrapManifest memory manifest = _manifest();
        manifest.currentRelease = address(_releaseAtVersion(SemVer.packSemVer(0, tooFar, 0), _emptyTable()));

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionMinorDeltaTooBig.selector,
                MAX_ALLOWED_MINOR_VERSION_DELTA,
                uint256(tooFar)
            )
        );
        new RegistryBootstrapMigration(manifest);
    }

    /// @dev Chains refuse an L2 upgrade transaction on a patch edge (`PatchCantSetUpgradeTxn`), and
    ///      a bootstrap release installs its whole L2 table.
    function test_revertWhen_bootstrapPatchCarriesAnL2Side() public {
        bytes[] memory table = _emptyTable();
        table[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.bytecodeInfo(BRIDGEHUB_IMPL_CODE);
        BootstrapManifest memory manifest = _manifestWithL2Plan(_authoredPlan());
        manifest.expectedProtocolVersion = newVersion;
        manifest.currentRelease = address(_releaseAtVersion(newVersion + 1, table));

        vm.expectRevert(PatchCannotCarryL2Upgrade.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_bootstrapPatchWithoutAnL2SideConstructs() public {
        BootstrapManifest memory manifest = _manifestWithExpectedVersion(newVersion);
        manifest.currentRelease = address(_releaseAtVersion(newVersion + 1, _emptyTable()));

        RegistryBootstrapMigration patch = new RegistryBootstrapMigration(manifest);
        assertEq(patch.newProtocolVersion(), newVersion + 1, "the edge targets the release's version");
        assertEq(patch.l2Plan().deployments.length, 0, "and carries no L2 side");
    }
}

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
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {IL2DelegateCalldataComposer} from "contracts/upgrades/registry/objects/IL2DelegateCalldataComposer.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {RegistryBootstrapMigration} from "contracts/upgrades/registry/bootstrap/RegistryBootstrapMigration.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade, ProposedUpgradeLib} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    MAX_NEW_FACTORY_DEPS,
    PRIORITY_TX_MAX_GAS_LIMIT,
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
    BootstrapNotYetExecuted,
    DeadlineNotYetPassed,
    L2BytecodeNotPublished,
    L2DelegateNotAnExtraDeployment,
    L2ExtraDeploymentNotBytecodeDerived,
    MalformedL2UpgradePlan,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch,
    RegistryDuplicateProxyRow,
    TimerNotStarted,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    AuthoredL2Plan,
    BootstrapManifest,
    L2UpgradePlan,
    ProxyUpgradeRow,
    GenesisFacet,
    ReleaseGenesisData,
    ReleaseManifest,
    PinnedContract
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
        ecosystemProxyAdmin = new ProxyAdmin();
        ecosystemProxy = new TransparentUpgradeableProxy(implV31, address(ecosystemProxyAdmin), hex"");
        chainAdmin = makeAddr("chainAdmin");
        notifierAdmin = new ProxyAdmin();
        notifierAdmin.transferOwnership(chainAdmin);
        notifierProxy = new TransparentUpgradeableProxy(implV31, address(notifierAdmin), hex"");

        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");
        upgradeEngine = makeAddr("upgradeEngine");
        vm.etch(upgradeEngine, hex"600043");
        delegateComposer = new FixedDelegateCalldataComposer(DELEGATE_CALLDATA);

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
        // An empty L2 table: the default edge derives no L2 deployments.
        genesisRelease = _deployRelease(new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT));
        migration = new RegistryBootstrapMigration(_manifest());
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    /// @dev A release pinning the fixture's facets, verifier and (ZKsync OS) DiamondInit over
    ///      `_l2BytecodeInfos`.
    function _deployRelease(bytes[] memory _l2BytecodeInfos) internal returns (CTMRelease result) {
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
                l2BytecodeInfos: _l2BytecodeInfos
            })
        );
    }

    /// @dev A genesis release whose table carries one canonical system-proxy row (the L2
    ///      Bridgehub), so the derived L2 set is nonempty. Its dependencies are the implementation
    ///      and the proxy shell.
    function _deployTableRelease() internal returns (CTMRelease) {
        bytes[] memory table = new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
        table[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.systemProxyRow(
            BRIDGEHUB_IMPL_CODE,
            SYSTEM_PROXY_CODE
        );
        return _deployRelease(table);
    }

    /// @dev The default edge is L1-only: the genesis release's table is empty and nothing is
    ///      authored, so the composed cut carries the all-zero L2 transaction `BaseZkSyncUpgrade`
    ///      skips.
    function _manifest() internal view returns (BootstrapManifest memory) {
        return _manifestWithL2Plan(_emptyL2Plan());
    }

    function _emptyL2Plan() internal pure returns (AuthoredL2Plan memory) {
        return
            AuthoredL2Plan({
                extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
                delegateTo: address(0),
                delegateComposer: _noPin(),
                factoryDepHashes: new uint256[](0)
            });
    }

    /// @dev The well-formed authored remainder: the delegate's Unsafe deployment at its
    ///      bytecode-derived address, the pinned composer defining its calldata, and the delegate's
    ///      bytecode as the one factory dependency.
    function _authoredPlan() internal view returns (AuthoredL2Plan memory) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory extras = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        extras[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        return
            AuthoredL2Plan({
                extraDeployments: extras,
                delegateTo: extras[0].newAddress,
                delegateComposer: _pin(address(delegateComposer)),
                factoryDepHashes: L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE))
            });
    }

    /// @dev Every bytecode an edge toward `_deployTableRelease()` installs: the delegate plus the
    ///      table row's implementation and proxy shell.
    function _tableCodes() internal pure returns (bytes[] memory) {
        return L2PlanFixtures.codes(DELEGATE_CODE, BRIDGEHUB_IMPL_CODE, SYSTEM_PROXY_CODE);
    }

    /// @dev `_authoredPlan()` toward `_tableRelease`, with the table row's dependencies joining the
    ///      delegate's and a nonzero schedule.
    function _tableManifest(CTMRelease _tableRelease) internal view returns (BootstrapManifest memory manifest) {
        AuthoredL2Plan memory plan = _authoredPlan();
        plan.factoryDepHashes = L2PlanFixtures.factoryDepHashes(_tableCodes());
        manifest = _manifestWithL2Plan(plan);
        manifest.currentRelease = PinnedContract({addr: address(_tableRelease), codehash: Utils.releaseCodehash()});
        manifest.upgradeTimestamp = PLAN_UPGRADE_TIMESTAMP;
    }

    function _manifestWithL2Plan(AuthoredL2Plan memory _l2Plan) internal view returns (BootstrapManifest memory) {
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
                upgradeEngine: _pin(upgradeEngine),
                l2Plan: _l2Plan,
                upgradeTimestamp: 0,
                ctmExecutor: _pin(address(ctmExecutor)),
                upgradeTimer: _pin(address(upgradeTimer))
            });
    }

    function _pin(address _addr) internal view returns (PinnedContract memory) {
        return PinnedContract({addr: _addr, codehash: _addr.codehash});
    }

    /// @dev The zero pin: no composer (the delegate is called with empty calldata).
    function _noPin() internal pure returns (PinnedContract memory) {
        return PinnedContract({addr: address(0), codehash: bytes32(0)});
    }

    /// @dev The L2 transaction the edge's FINAL plan composes, assembled here from the constants
    ///      the composer reads rather than through the library under test, so the equality below
    ///      is a real check of the composition.
    function _expectedL2Tx(
        L2UpgradePlan memory _plan,
        bytes memory _delegateCalldata
    ) internal view returns (L2CanonicalTransaction memory transaction) {
        transaction = ProposedUpgradeLib.emptyL2CanonicalTransaction();
        // VM identity comes off the release's DiamondInit, which the shared fixture builds with true.
        transaction.txType = ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
        transaction.from = uint256(uint160(L2_FORCE_DEPLOYER_ADDR));
        transaction.to = uint256(uint160(L2_COMPLEX_UPGRADER_ADDR));
        transaction.gasLimit = PRIORITY_TX_MAX_GAS_LIMIT;
        transaction.gasPerPubdataByteLimit = REQUIRED_L2_GAS_PRICE_PER_PUBDATA;
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(newVersion));
        transaction.nonce = minor;
        transaction.data = abi.encodeCall(
            IComplexUpgrader.forceDeployAndUpgradeUniversal,
            (_plan.deployments, _plan.delegateTo, _delegateCalldata)
        );
        transaction.factoryDeps = _plan.factoryDepHashes;
    }

    /// @dev The proposal the engine is handed: the release's verifier, the version edge, the
    ///      schedule and `_transaction`; the frozen struct's EraVM bytecode-hash words stay zero.
    function _expectedProposal(
        L2CanonicalTransaction memory _transaction,
        uint256 _upgradeTimestamp
    ) internal view returns (ProposedUpgrade memory proposal) {
        proposal = ProposedUpgradeLib.emptyProposedUpgrade(newVersion);
        proposal.l2ProtocolUpgradeTx = _transaction;
        proposal.verifier = address(testnetVerifier);
        proposal.upgradeTimestamp = _upgradeTimestamp;
    }

    /// @dev No facet cuts; the pinned engine's `upgrade(proposal)` as the init.
    function _expectedCut(ProposedUpgrade memory _proposal) internal view returns (Diamond.DiamondCutData memory) {
        return
            Diamond.DiamondCutData({
                facetCuts: new Diamond.FacetCut[](0),
                initAddress: upgradeEngine,
                initCalldata: abi.encodeCall(IDefaultUpgrade.upgrade, (_proposal))
            });
    }

    /// @dev Decodes an `upgrade(ProposedUpgrade)` init payload; external so the selector can be
    ///      sliced off calldata.
    function decodeUpgradeInit(bytes calldata _initCalldata) external pure returns (ProposedUpgrade memory) {
        assertEq(bytes32(bytes4(_initCalldata[:4])), bytes32(IDefaultUpgrade.upgrade.selector), "init selector");
        return abi.decode(_initCalldata[4:], (ProposedUpgrade));
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
        // The registry anchors are installed and the version edge committed with the cut the
        // object composes on-chain.
        assertEq(chainContractAddress.releaseCodehash(), Utils.releaseCodehash(), "anchor must be installed");
        assertEq(chainContractAddress.currentRelease(), address(genesisRelease), "release must be pinned");
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

    // ─────────────────────────────── composed payload ───────────────────────────────

    /// @dev The committed cut is composed ON-CHAIN from the pinned inputs — no cut bytes ride the
    ///      manifest. Against a genesis release whose table carries a row: the pinned engine's
    ///      `upgrade(proposal)` init over the release's verifier, the version edge, the schedule
    ///      and the L2 transaction built from the FINAL plan, whose delegate calldata the pinned
    ///      composer defines from that release and the CTM's Bridgehub.
    function test_upgradeCut_composesTheEngineInitOverTheProposalBuiltFromThePlan() public {
        CTMRelease tableRelease = _deployTableRelease();
        RegistryBootstrapMigration composed = new RegistryBootstrapMigration(_tableManifest(tableRelease));
        L2UpgradePlan memory plan = composed.l2Plan();

        vm.expectCall(
            address(delegateComposer),
            abi.encodeCall(
                IL2DelegateCalldataComposer.composeDelegateCalldata,
                (ICTMRelease(address(tableRelease)), address(bridgehub))
            )
        );
        Diamond.DiamondCutData memory cut = composed.upgradeCut();

        ProposedUpgrade memory expected = _expectedProposal(
            _expectedL2Tx(plan, DELEGATE_CALLDATA),
            PLAN_UPGRADE_TIMESTAMP
        );
        assertEq(
            keccak256(abi.encode(cut)),
            keccak256(abi.encode(_expectedCut(expected))),
            "the cut must be the engine init over the composed proposal"
        );
        assertEq(
            keccak256(abi.encode(composed.proposedUpgrade())),
            keccak256(abi.encode(expected)),
            "the served proposal is the one the cut embeds"
        );

        // The same bytes, read back field by field.
        assertEq(cut.facetCuts.length, 0, "the bootstrap cut carries no facet cuts");
        assertEq(cut.initAddress, upgradeEngine, "the init target is the pinned engine");
        ProposedUpgrade memory decoded = this.decodeUpgradeInit(cut.initCalldata);
        assertEq(decoded.verifier, address(testnetVerifier), "the verifier comes off the pinned release");
        assertEq(decoded.newProtocolVersion, newVersion);
        assertEq(decoded.upgradeTimestamp, PLAN_UPGRADE_TIMESTAMP, "the schedule is the manifest's");
        assertEq(decoded.bootloaderHash, bytes32(0));
        assertEq(decoded.defaultAccountHash, bytes32(0));
        assertEq(decoded.evmEmulatorHash, bytes32(0));
        _assertComposedL2Tx(decoded.l2ProtocolUpgradeTx, plan, DELEGATE_CALLDATA);
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
        assertEq(_transaction.gasLimit, PRIORITY_TX_MAX_GAS_LIMIT);
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
        bytes32 expectedHash = keccak256(
            abi.encode(
                _expectedCut(
                    _expectedProposal(_expectedL2Tx(composed.l2Plan(), DELEGATE_CALLDATA), PLAN_UPGRADE_TIMESTAMP)
                )
            )
        );

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
                (ICTMRelease(address(genesisRelease)), address(bridgehub))
            )
        );
        L2CanonicalTransaction memory transaction = authored.proposedUpgrade().l2ProtocolUpgradeTx;

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
        plan.delegateComposer = _noPin();
        RegistryBootstrapMigration uncomposed = _deployAndAuthorize(_manifestWithL2Plan(plan));
        L2UpgradePlan memory served = uncomposed.l2Plan();
        assertEq(served.delegateComposer, address(0), "no composer is served as zero");

        L2CanonicalTransaction memory transaction = uncomposed.proposedUpgrade().l2ProtocolUpgradeTx;
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
        // The authored extra follows, unchanged.
        assertEq(
            abi.encode(plan.deployments[1]),
            abi.encode(manifest.l2Plan.extraDeployments[0]),
            "the authored extra is appended after the derived set"
        );
        assertEq(plan.delegateTo, manifest.l2Plan.delegateTo);
        assertEq(plan.delegateTo, plan.deployments[1].newAddress, "the delegate is the authored Unsafe extra");
        assertEq(plan.delegateComposer, address(delegateComposer), "the pinned composer is served");
        assertEq(plan.factoryDepHashes, manifest.l2Plan.factoryDepHashes, "dependencies ride through");
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

        ProposedUpgrade memory proposal = migration.proposedUpgrade();
        assertEq(proposal.l2ProtocolUpgradeTx.txType, 0, "no L2 side composes no L2 transaction");
        assertEq(proposal.verifier, address(testnetVerifier));
        assertEq(proposal.newProtocolVersion, newVersion);
        assertEq(proposal.upgradeTimestamp, 0);
        assertEq(
            keccak256(abi.encode(migration.upgradeCut())),
            keccak256(abi.encode(_expectedCut(_expectedProposal(ProposedUpgradeLib.emptyL2CanonicalTransaction(), 0)))),
            "an L1-only edge is the engine init over an L2-less proposal"
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
            authored.proposedUpgrade().l2ProtocolUpgradeTx.txType,
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

    // ─────────────────────────── engine and composer pins ───────────────────────────

    /// @dev The engine is the code the committed cut delegatecalls into on every chain, so it is
    ///      held against live code like every other pin. A manifest whose pin disagrees still
    ///      constructs (pins are checked on the execution path) but refuses to migrate.
    function test_revertWhen_upgradeEnginePinMismatch() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeEngine.codehash = keccak256("not the engine's code");
        RegistryBootstrapMigration mispinned = _deployAndAuthorize(manifest);
        uint256 oldVersion = chainContractAddress.protocolVersion();
        assertEq(mispinned.upgradeCut().initAddress, upgradeEngine, "the engine is served like any pinned address");

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                upgradeEngine,
                keccak256("not the engine's code"),
                upgradeEngine.codehash
            )
        );
        mispinned.migrate();
        assertFalse(mispinned.executed(), "a refused edge must stay unspent");
        assertEq(chainContractAddress.upgradeCutHash(oldVersion), bytes32(0), "a refused edge commits no cut");
    }

    /// @dev The composer is version-specific CODE pinned in place of calldata, so when the plan
    ///      names one it is held exactly like the engine.
    function test_revertWhen_delegateComposerPinMismatch() public {
        AuthoredL2Plan memory plan = _authoredPlan();
        plan.delegateComposer.codehash = keccak256("not the composer's code");
        RegistryBootstrapMigration mispinned = _deployAndAuthorize(_manifestWithL2Plan(plan));
        assertEq(
            mispinned.l2Plan().delegateComposer,
            address(delegateComposer),
            "the composer is served like every other pinned address"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(delegateComposer),
                keccak256("not the composer's code"),
                address(delegateComposer).codehash
            )
        );
        mispinned.migrate();
        assertFalse(mispinned.executed(), "a refused edge must stay unspent");
    }

    // ─────────────────────────── manifest shape ───────────────────────────

    function test_revertWhen_upgradeEngineIsZero() public {
        BootstrapManifest memory manifest = _manifest();
        manifest.upgradeEngine = _noPin();

        vm.expectRevert(ZeroAddress.selector);
        new RegistryBootstrapMigration(manifest);
    }

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

    // ─────────────────────────── L2 plan shape ───────────────────────────
    // The same rules {CTMTransition} enforces, run against the COMBINED (derived + authored) plan
    // at construction, so an edge whose L2 leg cannot execute refuses to exist. One test per rule,
    // each on an otherwise well-formed plan so exactly that rule fires.

    function test_revertWhen_authoredDeploymentsWithoutDelegateTarget() public {
        // Force-deployments but no delegate target: `L2ComplexUpgrader` always ends with the final
        // delegatecall, so a deployments-only plan would construct here yet revert on L2 forever.
        // (The composer is cleared so ONLY the deployments-without-target rule can fire.)
        AuthoredL2Plan memory plan = _authoredPlan();
        plan.delegateTo = address(0);
        plan.delegateComposer = _noPin();

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new RegistryBootstrapMigration(manifest);
    }

    /// @dev The genesis release's table decides whether the derived set is empty: against a
    ///      release with a row, an edge that authors NOTHING still needs its delegate.
    function test_revertWhen_derivedDeploymentsWithoutDelegateTarget() public {
        CTMRelease tableRelease = _deployTableRelease();
        AuthoredL2Plan memory plan = _emptyL2Plan();
        // The derived row's dependencies are present, so only the shape rule can fire.
        plan.factoryDepHashes = L2PlanFixtures.factoryDepHashes(
            L2PlanFixtures.codes(BRIDGEHUB_IMPL_CODE, SYSTEM_PROXY_CODE)
        );
        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);
        manifest.currentRelease = PinnedContract({addr: address(tableRelease), codehash: Utils.releaseCodehash()});

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_delegateComposerWithoutTarget() public {
        // Code defining calldata for a delegate call that never happens.
        AuthoredL2Plan memory plan = _emptyL2Plan();
        plan.delegateComposer = _pin(address(delegateComposer));

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_factoryDepsWithoutL2Side() public {
        // Dependencies with no transaction to ride in.
        AuthoredL2Plan memory plan = _emptyL2Plan();
        plan.factoryDepHashes = L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE));

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new RegistryBootstrapMigration(manifest);
    }

    /// @dev A plan carrying more factory deps than `BaseZkSyncUpgrade` accepts must be rejected at
    ///      pin time: otherwise the edge commits and every per-chain upgrade then reverts.
    function test_revertWhen_factoryDepsExceedTheCap() public {
        AuthoredL2Plan memory plan = _authoredPlan();
        // The delegate's real hash stays in front (so the presence rule holds); surplus dummies
        // push the list one past the cap.
        uint256[] memory tooManyDeps = new uint256[](MAX_NEW_FACTORY_DEPS + 1);
        tooManyDeps[0] = plan.factoryDepHashes[0];
        for (uint256 i = 1; i < tooManyDeps.length; ++i) {
            tooManyDeps[i] = i;
        }
        plan.factoryDepHashes = tooManyDeps;

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_extraIsNotAtItsBytecodeDerivedAddress() public {
        // An extra may only land on the address its own bytecode info derives — never on a fixed
        // built-in or a table-derived target.
        AuthoredL2Plan memory plan = _authoredPlan();
        address derived = plan.extraDeployments[0].newAddress;
        address elsewhere = makeAddr("elsewhere");
        plan.extraDeployments[0].newAddress = elsewhere;
        plan.delegateTo = elsewhere;

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(abi.encodeWithSelector(L2ExtraDeploymentNotBytecodeDerived.selector, derived, elsewhere));
        new RegistryBootstrapMigration(manifest);
    }

    function test_revertWhen_delegateIsNotAnExtraDeployment() public {
        // The code the upgrade delegatecalls into must be pinned by a bytecode hash the manifest
        // carries: the delegate must be one of the extras.
        AuthoredL2Plan memory plan = _authoredPlan();
        address stranger = makeAddr("notAnExtra");
        plan.delegateTo = stranger;

        BootstrapManifest memory manifest = _manifestWithL2Plan(plan);

        vm.expectRevert(abi.encodeWithSelector(L2DelegateNotAnExtraDeployment.selector, stranger));
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

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IManifestHash} from "contracts/upgrades/registry/objects/IManifestHash.sol";
import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {StorageSlot} from "@openzeppelin/contracts-v4/utils/StorageSlot.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {CoreTransition} from "contracts/upgrades/registry/objects/CoreTransition.sol";
import {ICoreTransition} from "contracts/upgrades/registry/objects/ICoreTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {IEcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/IEcosystemUpgradeOperation.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {IDomainUpgradeExecutor} from "contracts/upgrades/registry/executors/IDomainUpgradeExecutor.sol";
import {ICoreUpgradeExecutor} from "contracts/upgrades/registry/executors/ICoreUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {IEcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/IEcosystemUpgradeExecutor.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {
    L2BytecodeNotPublished,
    OperationManifestChanged,
    ProxyUpgradeRowMismatch,
    RegistryTargetHasNoCode,
    TransitionReleaseMismatch,
    Unauthorized,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    CoreTransitionManifest,
    OperationManifest,
    ProxyUpgradeRow
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @dev Three distinct implementations so a proxy row is a real `expectedOldImpl -> implNew`
///      edge and a proxy can also sit at an implementation the row does not know.
contract ExecutionImplOld {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract ExecutionImplNew {
    function version() external pure returns (uint256) {
        return 2;
    }
}

contract ExecutionImplOther {
    function version() external pure returns (uint256) {
        return 3;
    }
}

/// @dev An implementation whose reinitializer re-points its own proxy elsewhere: a swap whose end
///      state is not the row's `implNew`. The write happens inside the upgrade call, through the
///      proxy's own delegatecall; the test itself touches no storage.
contract SelfRepointingImpl {
    bytes32 internal constant IMPLEMENTATION_SLOT = bytes32(uint256(keccak256("eip1967.proxy.implementation")) - 1);
    address internal immutable REPOINT_TO;

    constructor(address _repointTo) {
        REPOINT_TO = _repointTo;
    }

    function initializeUpgrade() external {
        StorageSlot.getAddressSlot(IMPLEMENTATION_SLOT).value = REPOINT_TO;
    }
}

/// @notice The coordinator's one atomic `execute(operation)` over one CTM
///         ({protocol-docs/ecosystem-upgrade-coordination.md}): the happy path and its end state,
///         authority and domain bindings, all-or-nothing execution (a failure in any leg reverts
///         every leg), stale and garbage operations refused, the manifest read once and held to its
///         hash, and no migration pause needed or touched. The single-CTM binding and succession are
///         EcosystemUpgradeCoordination.t.sol.
/// @dev The "full" operation names all three changes: an ecosystem leg (a `CoreTransition` with one
///      row over a proxy under the core executor's `ProxyAdmin`), a CTM-domain row (a proxy under the
///      CTM executor's `ProxyAdmin`, in the `ValidatorTimelock` slot) and the fixture's transition.
///      The chain-side crossing (`upgradeChain`) with a real upgrade engine is
///      RegistryDrivenUpgrade.t.sol's business; the fixture engine is a pinned stand-in.
contract OperationExecutionTest is CTMUpgradeExecutorFixture {
    address internal implOld;
    address internal implNew;
    address internal implOther;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    TransparentUpgradeableProxy internal ecosystemProxy;
    TransparentUpgradeableProxy internal otherEcosystemProxy;
    CoreTransition internal coreTransition;
    CoreTransition internal otherCoreTransition;

    function setUp() public override {
        super.setUp();
        implOld = address(new ExecutionImplOld());
        implNew = address(new ExecutionImplNew());
        implOther = address(new ExecutionImplOther());
        // One proxy per authority domain, each under the ProxyAdmin its executor owns.
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        otherEcosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        coreTransition = _deployCoreTransition(address(ecosystemProxy));
        otherCoreTransition = _deployCoreTransition(address(otherEcosystemProxy));
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _row(
        address _proxy,
        address _expectedOldImpl,
        address _implNew
    ) internal pure returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: _implNew,
                callInitializeUpgrade: false
            });
    }

    /// @dev A core transition with one real edge (`implOld -> implNew`) on `_proxy`, in the
    ///      L1Bridgehub slot (the slot is a label — the row's own proxy address is its identity).
    function _deployCoreTransition(address _proxy) internal returns (CoreTransition) {
        CoreTransitionManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = _row(_proxy, implOld, implNew);
        return new CoreTransition(manifest);
    }

    /// @dev The CTM-domain inventory the "full" operation carries: one row over a proxy under
    ///      the executor's own `ProxyAdmin`, departing from `_expectedOldImpl` toward `_implNew`.
    function _ctmInventory(
        address _expectedOldImpl,
        address _implNew,
        bool _callInitializeUpgrade
    ) internal view returns (ProxyUpgradeRow[] memory inventory) {
        inventory = _emptyInventory();
        inventory[uint256(CTMContract.ValidatorTimelock)] = ProxyUpgradeRow({
            proxy: address(ctmDomainProxy),
            expectedOldImpl: _expectedOldImpl,
            implNew: _implNew,
            callInitializeUpgrade: _callInitializeUpgrade
        });
    }

    /// @dev The fixture's default transition under an operation that names all three changes.
    function _deployFullTransition() internal returns (CTMTransition full) {
        full = _deployTransition(777);
        _deployFullOperation(full);
    }

    function _deployFullOperation(CTMTransition _transition) internal returns (EcosystemUpgradeOperation operation) {
        operation = _deployOperation(
            address(coreTransition),
            _ctmInventory(implOld, implNew, false),
            address(_transition)
        );
        operationOf[address(_transition)] = operation;
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

    function _executeAs(address _caller, IEcosystemUpgradeOperation _operation) internal {
        vm.prank(_caller);
        coordinator.execute(_operation);
    }

    /// @dev What a refused execution must leave: the CTM at its version and release with nothing
    ///      committed, and both domains' proxies where they were.
    function _assertNothingApplied() internal view {
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version must not move");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "no transition must be committed");
        assertEq(chainContractAddress.currentRelease(), address(fromRelease), "the release must not move");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the ecosystem leg must not stand");
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    /// @dev One call applies the ecosystem leg FIRST, then the CTM leg (rows, version commit,
    ///      release pin), and emits one coordinator event.
    function test_execute_eventsAndEndState() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        uint256 oldVersion = chainContractAddress.protocolVersion();

        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ecosystemProxy), implNew);
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ICoreUpgradeExecutor.L1UpgradeApplied(address(coreTransition));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ProxyUpgradeRowLib.ProxyImplementationUpgraded(address(ctmDomainProxy), implNew);
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewProtocolVersion(oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ICTMUpgradeExecutor.CTMUpgradeApplied(address(full), oldVersion, newVersion);
        vm.expectEmit(true, true, true, true, address(coordinator));
        emit IEcosystemUpgradeExecutor.OperationExecuted(address(operation));
        _executeAs(governor, operation);

        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.upgradeTransition(oldVersion), address(full));
        assertEq(chainContractAddress.currentRelease(), address(release));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the ecosystem row must be applied");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the CTM-domain row must be applied");
        // The post-state check `applyOperation` ends with keeps holding afterwards.
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(full)));
    }

    /// @dev The operation is the reviewable, queryable record of what was executed.
    function test_operationManifestIsQueryable() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        assertEq(operation.coreTransition(), address(coreTransition));
        assertEq(operation.ctmTransition(), address(full));
        assertEq(operation.ctmInfrastructureRows().length, 1);
        assertEq(address(coordinator.ctmExecutor()), address(ctmExecutor));
        assertEq(operation.manifestHash(), keccak256(abi.encode(operation.getManifest())));
    }

    /// @dev No migration pause is involved: `execute` runs with none held and pauses nothing, and an
    ///      ecosystem pause governance holds for incident control is left exactly as it was.
    function test_execute_neitherNeedsNorTouchesMigrationPauses() public {
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "fixture: unpaused");
        _execute(transition);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "commits without a pause");
        assertFalse(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "and pauses nothing");

        vm.prank(governor);
        chainAssetHandler.pauseMigration();
        address appliedRelease = address(release);
        newVersion = SemVer.packSemVer(0, 2, 0);
        release = _deployRelease(4, newVersion);
        CTMTransition next = _deployTransitionFrom(880, appliedRelease);
        _execute(next);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "commits under an ecosystem pause too");
        assertTrue(chainAssetHandler.migrationPausedFor(address(chainContractAddress)), "which it leaves in place");
        assertFalse(chainAssetHandler.ctmMigrationPaused(address(chainContractAddress)), "and takes no CTM pause");
    }

    /// @dev The owner path of the core executor is unaffected by the coordinator: the bootstrap
    ///      edge and recovery apply a core transition directly.
    function test_ecosystemLeg_ownerStillAppliesDirectly() public {
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ICoreUpgradeExecutor.L1UpgradeApplied(address(coreTransition));
        vm.prank(governor);
        coreExecutor.applyL1Upgrade(ICoreTransition(address(coreTransition)));
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew);
    }

    // ─────────────────────────── authority and bindings ───────────────────────────

    function test_revertWhen_executeCalledByStranger() public {
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        vm.expectRevert("Ownable: caller is not the owner");
        _executeAs(makeAddr("stranger"), operation);
        _assertNothingApplied();
    }

    /// @dev A coordinator the domains do not name gets nothing — a shared owner and the same code
    ///      are not authorization. The domains enforce it themselves (`onlyCoordinator`): a foreign
    ///      coordinator with no CTM executor refuses before reading the operation, one bound to an
    ///      executor of its own over the same CTM is refused by the core executor, and the fixture's
    ///      CTM executor refuses it at the callback.
    function test_revertWhen_aForeignCoordinatorDrivesTheDomains() public {
        EcosystemUpgradeExecutor foreign = new EcosystemUpgradeExecutor(governor, coreExecutor);
        EcosystemUpgradeOperation full = _operationFor(_deployFullTransition());

        vm.expectRevert(ZeroAddress.selector);
        vm.prank(governor);
        foreign.execute(full);

        CTMUpgradeExecutor foreignCTMExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            address(foreign)
        );
        vm.prank(governor);
        foreign.setCTMExecutor(foreignCTMExecutor);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(foreign)));
        vm.prank(governor);
        foreign.execute(full);

        OperationManifest memory manifest = full.getManifest();
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(foreign)));
        vm.prank(address(foreign));
        ctmExecutor.applyOperation(manifest);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(foreign)));
        vm.prank(address(foreign));
        coreExecutor.applyOperation(manifest);
        _assertNothingApplied();
    }

    /// @dev Each domain enforces its binding at the callback: a detached CTM executor refuses the
    ///      coordinator, and the core leg applied before it is rolled back with the call.
    function test_revertWhen_theCTMExecutorDoesNotNameTheCoordinator() public {
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        vm.prank(governor);
        ctmExecutor.setCoordinator(address(0));

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(coordinator)));
        _executeAs(governor, operation);
        _assertNothingApplied();

        vm.prank(governor);
        ctmExecutor.setCoordinator(address(coordinator));
        _executeAs(governor, operation);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "executes once bound again");
    }

    function test_revertWhen_theCoreExecutorDoesNotNameTheCoordinator() public {
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        vm.prank(governor);
        coreExecutor.setCoordinator(address(0));

        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(coordinator)));
        _executeAs(governor, operation);
        _assertNothingApplied();
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the CTM leg never ran");
    }

    /// @dev An executor that does not (yet) own its CTM cannot commit on it — the pre-bootstrap
    ///      state — and the rows applied before the commit are rolled back with it.
    function test_revertWhen_theExecutorDoesNotOwnItsCTM() public {
        vm.prank(address(ctmExecutor));
        Ownable2Step(address(chainContractAddress)).transferOwnership(governor);
        vm.prank(governor);
        Ownable2Step(address(chainContractAddress)).acceptOwnership();
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());

        vm.expectRevert("Ownable: caller is not the owner");
        _executeAs(governor, operation);
        _assertNothingApplied();
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the CTM-domain row is rolled back");
    }

    function test_replaceCoordinator_thenExecute() public {
        EcosystemUpgradeExecutor successor = new EcosystemUpgradeExecutor(governor, coreExecutor);
        vm.startPrank(governor);
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit IDomainUpgradeExecutor.CoordinatorChanged(address(coordinator), address(successor));
        coreExecutor.setCoordinator(address(successor));
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit IDomainUpgradeExecutor.CoordinatorChanged(address(coordinator), address(successor));
        ctmExecutor.setCoordinator(address(successor));
        successor.setCTMExecutor(ctmExecutor);
        vm.stopPrank();
        assertEq(coreExecutor.coordinator(), address(successor));
        assertEq(ctmExecutor.coordinator(), address(successor));

        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        // The predecessor is refused by the domains it no longer drives.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(coordinator)));
        _executeAs(governor, operation);

        vm.prank(governor);
        successor.execute(operation);
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew);
        assertEq(chainContractAddress.protocolVersion(), newVersion);
    }

    function test_rejectUnauthorizedCoordinatorReplacement() public {
        vm.startPrank(makeAddr("unprivileged"));
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.setCoordinator(makeAddr("successor"));
        vm.expectRevert("Ownable: caller is not the owner");
        coreExecutor.setCoordinator(makeAddr("successor"));
        vm.stopPrank();
        assertEq(ctmExecutor.coordinator(), address(coordinator));
        assertEq(coreExecutor.coordinator(), address(coordinator));
    }

    // ─────────────────────────── all or nothing ───────────────────────────

    /// @dev The CTM leg applies infrastructure rows BEFORE the version commit (the commit may need a
    ///      setter only the implementation this very operation installs has), so the case that
    ///      proves atomicity for a MIXED operation is the reverse one: the ecosystem leg and the rows
    ///      that already applied must be rolled back when the transition leg then fails. Here the
    ///      transition's L2 delegate was never published on the CTM's supplier.
    function test_revertWhen_theTransitionFailsAfterTheRows_everyLegIsRolledBack() public {
        bytes memory unpublishedDelegate = hex"de2f";
        CTMTransition unpublished = _deployTransitionWithDelegate(
            777,
            chainContractAddress.currentRelease(),
            unpublishedDelegate
        );
        assertEq(bytecodesSupplier.evmPublishingBlock(keccak256(unpublishedDelegate)), 0, "fixture: not yet published");
        EcosystemUpgradeOperation operation = _deployFullOperation(unpublished);

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(unpublishedDelegate)));
        _executeAs(governor, operation);
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the infrastructure row is rolled back");
        _assertNothingApplied();

        // Publishing the missing dependency makes the very same operation executable, rows and all.
        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(unpublishedDelegate));
        _executeAs(governor, operation);
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the row applies once the call can complete");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "and so does the ecosystem leg");
        assertEq(chainContractAddress.protocolVersion(), newVersion, "and the version commit");
    }

    /// @dev A CTM-domain row whose proxy sits at an implementation the row does not know fails the
    ///      source check; the ecosystem leg ran FIRST in the same call and is rolled back too.
    function test_revertWhen_aCtmRowDepartsFromAnUnexpectedImplementation() public {
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        // Something moved the CTM-domain proxy on before the operation ran (an owner raw call
        // through the executor, which owns the admin).
        vm.prank(governor);
        ctmExecutor.forward(_singleCall(address(ctmProxyAdmin), _moveProxyCall(ctmDomainProxy, implOther)));

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), implOld, implOther)
        );
        _executeAs(governor, operation);
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOther, "the offending proxy is left where it was");
        _assertNothingApplied();
    }

    /// @dev The same for the ecosystem leg, which fails before the CTM leg is reached.
    function test_revertWhen_anEcosystemRowDepartsFromAnUnexpectedImplementation() public {
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        vm.prank(governor);
        coreExecutor.forward(_singleCall(address(ecosystemProxyAdmin), _moveProxyCall(ecosystemProxy, implOther)));

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ecosystemProxy), implOld, implOther)
        );
        _executeAs(governor, operation);
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOther, "the offending proxy is left where it was");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the CTM leg never ran");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "nothing is committed");
    }

    /// @dev A CTM-domain row whose swap does not END at its `implNew` (the reinitializer re-points
    ///      the proxy) fails the leg's own verification, so nothing of the call stands.
    function test_revertWhen_aCtmRowEndsOffItsTarget() public {
        address repointing = address(new SelfRepointingImpl(implOther));
        CTMTransition t = _deployTransition(777);
        EcosystemUpgradeOperation operation = _deployOperation(
            address(coreTransition),
            _ctmInventory(implOld, repointing, true),
            address(t)
        );

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ctmDomainProxy), repointing, implOther)
        );
        _executeAs(governor, operation);
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "the row is rolled back");
        _assertNothingApplied();
    }

    /// @dev The same for the ecosystem leg.
    function test_revertWhen_anEcosystemRowEndsOffItsTarget() public {
        address repointing = address(new SelfRepointingImpl(implOther));
        CoreTransitionManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(ecosystemProxy),
            expectedOldImpl: implOld,
            implNew: repointing,
            callInitializeUpgrade: true
        });
        CoreTransition repointingCore = new CoreTransition(manifest);
        EcosystemUpgradeOperation operation = _deployOperation(
            address(repointingCore),
            _emptyInventory(),
            address(_deployTransition(777))
        );

        vm.expectRevert(
            abi.encodeWithSelector(ProxyUpgradeRowMismatch.selector, address(ecosystemProxy), repointing, implOther)
        );
        _executeAs(governor, operation);
        _assertNothingApplied();
    }

    // ─────────────────────────── stale and garbage operations ───────────────────────────

    /// @dev Stale: an operation whose transition departs from a release the CTM has left (another
    ///      operation moved it on first) is refused, with nothing of its other legs applied.
    function test_revertWhen_theOperationDepartsFromAReleaseTheCTMLeft() public {
        EcosystemUpgradeOperation stale = _operationFor(_deployFullTransition());
        CTMTransition competing = _deployTransitionFrom(778, address(fromRelease));
        _execute(competing);

        vm.expectRevert(
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, address(fromRelease), address(release))
        );
        _executeAs(governor, stale);
        assertEq(chainContractAddress.upgradeTransition(0), address(competing), "the competing commit stands");
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implOld, "the stale ecosystem leg never stands");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implOld, "nor its CTM-domain row");
    }

    function test_revertWhen_executeWithAnUndeployedOperation() public {
        address codeless = makeAddr("codelessOperation");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        _executeAs(governor, IEcosystemUpgradeOperation(codeless));
        _assertNothingApplied();
    }

    /// @dev Without the check a call into the codeless address would succeed silently and the leg
    ///      would report itself applied over nothing.
    function test_revertWhen_theOperationNamesAnUndeployedCoreTransition() public {
        address codeless = makeAddr("codelessCoreTransition");
        EcosystemUpgradeOperation misnamed = _operationWithCore(ICTMTransition(address(transition)), codeless);

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        _executeAs(governor, misnamed);
        _assertNothingApplied();
    }

    function test_revertWhen_theOperationNamesAnUndeployedTransition() public {
        address codeless = makeAddr("codelessTransition");
        EcosystemUpgradeOperation operation = _cachedOperationFor(ICTMTransition(codeless));

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        _executeAs(governor, operation);
        _assertNothingApplied();
    }

    /// @dev Garbage: an object whose `manifestHash()` does not commit to the manifest it serves is
    ///      refused before any leg runs. A genuine `EcosystemUpgradeOperation` cannot disagree with
    ///      itself (its manifest is write-once), so the disagreement is mocked: the test isolates
    ///      the coordinator's check from the object.
    function test_revertWhen_theOperationHashDoesNotCommitToItsManifest() public {
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        bytes32 committed = keccak256("not this manifest");
        vm.mockCall(address(operation), abi.encodeCall(IManifestHash.manifestHash, ()), abi.encode(committed));

        vm.expectRevert(
            abi.encodeWithSelector(
                OperationManifestChanged.selector,
                committed,
                keccak256(abi.encode(operation.getManifest()))
            )
        );
        _executeAs(governor, operation);
        _assertNothingApplied();
    }

    /// @dev The same check from the other side: a served manifest that no longer hashes to the
    ///      object's commitment is refused even under an unchanged `manifestHash()` (mocked, as
    ///      above), so a swapped-in leg never runs.
    function test_revertWhen_theOperationServesAnotherManifestUnderItsHash() public {
        EcosystemUpgradeOperation operation = _operationFor(_deployFullTransition());
        bytes32 committed = operation.manifestHash();
        OperationManifest memory changed = operation.getManifest();
        changed.coreTransition = address(otherCoreTransition);
        vm.mockCall(address(operation), abi.encodeCall(EcosystemUpgradeOperation.getManifest, ()), abi.encode(changed));

        vm.expectRevert(
            abi.encodeWithSelector(OperationManifestChanged.selector, committed, keccak256(abi.encode(changed)))
        );
        _executeAs(governor, operation);
        assertEq(_liveImpl(ecosystemProxyAdmin, otherEcosystemProxy), implOld, "the swapped-in leg never runs");
        _assertNothingApplied();
    }

    /// @dev The operation's per-field getters never steer an execution: the coordinator reads the
    ///      manifest alone and hands each domain its leg. Every getter names a decoy here (another
    ///      core transition, another CTM transition, a foreign row); the manifest's objects run, and
    ///      no getter is called.
    function test_executeReadsTheManifestNeverTheGetters() public {
        CTMTransition full = _deployFullTransition();
        EcosystemUpgradeOperation operation = _operationFor(full);
        CTMTransition decoyTransition = _deployTransition(779);
        ProxyUpgradeRow[] memory decoyRows = new ProxyUpgradeRow[](1);
        decoyRows[0] = _row(address(otherEcosystemProxy), implOld, implOther);
        vm.mockCall(
            address(operation),
            abi.encodeCall(EcosystemUpgradeOperation.coreTransition, ()),
            abi.encode(address(otherCoreTransition))
        );
        vm.mockCall(
            address(operation),
            abi.encodeCall(EcosystemUpgradeOperation.ctmTransition, ()),
            abi.encode(address(decoyTransition))
        );
        vm.mockCall(
            address(operation),
            abi.encodeCall(EcosystemUpgradeOperation.ctmInfrastructureRows, ()),
            abi.encode(decoyRows)
        );
        vm.expectCall(address(operation), abi.encodeCall(EcosystemUpgradeOperation.coreTransition, ()), 0);
        vm.expectCall(address(operation), abi.encodeCall(EcosystemUpgradeOperation.ctmTransition, ()), 0);
        vm.expectCall(address(operation), abi.encodeCall(EcosystemUpgradeOperation.ctmInfrastructureRows, ()), 0);

        _executeAs(governor, operation);
        assertEq(_liveImpl(ecosystemProxyAdmin, ecosystemProxy), implNew, "the manifest's core row applied");
        assertEq(_liveImpl(ecosystemProxyAdmin, otherEcosystemProxy), implOld, "the decoy core leg never ran");
        assertEq(_liveImpl(ctmProxyAdmin, ctmDomainProxy), implNew, "the manifest's CTM row applied");
        assertEq(chainContractAddress.upgradeTransition(0), address(full), "the manifest's transition committed");
    }
}

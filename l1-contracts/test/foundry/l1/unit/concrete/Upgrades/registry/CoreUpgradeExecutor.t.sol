// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/objects/ICoreRegistry.sol";
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {IEcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/IEcosystemUpgradeOperation.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {
    LegNotReserved,
    NoPendingOperation,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch,
    Unauthorized,
    UpgradeLifecycleBusy,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
    CTMLeg,
    OperationManifest,
    ProxyUpgradeRow,
    PinnedContract
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";
import {
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "../../../../../../../contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @dev Not a `CoreRegistry`: exercises the executor's codehash provenance check.
contract NotACoreRegistry {
    function manifestHash() external pure returns (bytes32) {
        return bytes32(uint256(1));
    }
}

/// @dev The one CTM-executor getter an operation's constructor reads. MOCKED deliberately: this
///      suite isolates the core executor's reservation rules, and an operation must name a CTM leg
///      to exist at all; the CTM side of a lifecycle is CTMUpgradeLifecycle.t.sol's business.
contract StubCTMExecutor {
    // solhint-disable-next-line var-name-mixedcase
    IChainTypeManager public immutable CHAIN_TYPE_MANAGER;

    constructor(address _ctm) {
        CHAIN_TYPE_MANAGER = IChainTypeManager(_ctm);
    }
}

/// @dev Minimal implementation contracts for proxy-upgrade tests.
contract DummyImplA {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract DummyImplB {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Tests the ecosystem-domain executor on its own: the owner path (how the bootstrap
///         edge applies a registry), the post-state check, and the reservation protocol the
///         coordinator drives it through. Deliberately owned by a DIFFERENT governance address
///         than the CTM-scoped executor in CTMUpgradeExecutor.t.sol: the two authority domains
///         are separable.
/// @dev Registries are REAL, factory-deployed `CoreRegistry` instances: the executor enforces
///      factory provenance, so a mutable test double is rejected by design — which this suite
///      also asserts.
/// @dev The COORDINATOR IS A PLAIN ADDRESS here, pranked: this suite isolates the executor's own
///      rules (who may reserve, apply and release, and for which registry) from the coordinator's
///      stage logic. Operations are REAL write-once `EcosystemUpgradeOperation` objects — the
///      executor reads its leg from them — over a stub CTM leg (see `StubCTMExecutor`); the real
///      coordinator drives the same callbacks end to end in CTMUpgradeLifecycle.t.sol and
///      EcosystemUpgradeCoordination.t.sol.
contract CoreUpgradeExecutorTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal ecosystemGovernor = makeAddr("ecosystemGovernor");
    address internal coordinator = makeAddr("coordinator");
    StubCTMExecutor internal stubCtmExecutor;
    /// @dev The default operation: the fixture registry as its ecosystem leg, one stub CTM leg.
    IEcosystemUpgradeOperation internal operation;

    CoreUpgradeExecutor internal coreExecutor;
    ICoreRegistry internal coreRegistry;
    bytes32 internal coreRegistryCodehash;
    ProxyAdmin internal proxyAdmin;

    DummyImplA internal implOld;
    DummyImplB internal implNew;
    TransparentUpgradeableProxy internal bridgehubProxy;
    TransparentUpgradeableProxy internal messageRootProxy;

    function setUp() public {
        implOld = new DummyImplA();
        implNew = new DummyImplB();

        proxyAdmin = new ProxyAdmin();
        bridgehubProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");
        messageRootProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");

        // Bridgehub is a full source-checked edge (old -> new); MessageRoot pins its live
        // implementation (the executor's live comparison must skip it). Every row must be a real,
        // unique edge — a placeholder (all-zero) row is rejected at the registry boundary.
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](2);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        rows[1] = _row(address(messageRootProxy), address(implOld), address(implOld));
        coreRegistry = _deployRegistry(rows);
        coreRegistryCodehash = address(coreRegistry).codehash;

        // The executor is BOUND to (and owns) one immutable ecosystem ProxyAdmin and pins the
        // audited `CoreRegistry` codehash, mirroring the production ownership chain; the owner
        // then points it at the coordinator (the v34 bootstrap's stage-2 binding).
        coreExecutor = new CoreUpgradeExecutor(ecosystemGovernor, proxyAdmin, coreRegistryCodehash);
        proxyAdmin.transferOwnership(address(coreExecutor));
        vm.prank(ecosystemGovernor);
        coreExecutor.setCoordinator(coordinator);

        stubCtmExecutor = new StubCTMExecutor(makeAddr("ctm"));
        operation = _operationNaming(address(coreRegistry));
    }

    /// @dev A one-leg operation whose ecosystem leg is `_coreRegistry` (zero for none).
    function _operationNaming(address _coreRegistry) internal returns (IEcosystemUpgradeOperation) {
        CTMLeg[] memory legs = new CTMLeg[](1);
        legs[0] = CTMLeg({executor: address(stubCtmExecutor), transition: makeAddr("transition")});
        return new EcosystemUpgradeOperation(OperationManifest({coreRegistry: _coreRegistry, legs: legs}));
    }

    function _row(
        address _proxy,
        address _expectedOldImpl,
        address _implNew
    ) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: PinnedContract({addr: _implNew, codehash: _implNew.codehash}),
                callInitializeUpgrade: false,
                admin: ProxyAdmin(address(0))
            });
    }

    /// @dev The registry takes the enum-indexed inventory; these tests exercise row semantics
    ///      with two synthetic proxies, so they occupy the `L1Bridgehub` and `L1MessageRoot`
    ///      slots (the slot is a label — the row's own proxy address is its identity).
    function _deployRegistry(ProxyUpgradeRow[] memory _rows) internal returns (ICoreRegistry) {
        CoreRegistryManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        if (_rows.length > 0) {
            manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = _rows[0];
        }
        if (_rows.length > 1) {
            manifest.proxyUpgrades[uint256(L1EcosystemContract.L1MessageRoot)] = _rows[1];
        }
        return ICoreRegistry(address(new CoreRegistry(manifest)));
    }

    function _liveImpl(TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(_proxy), EIP1967_IMPL_SLOT))));
    }

    function _applyL1Upgrade() internal {
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(coreRegistry);
    }

    function _reserve(IEcosystemUpgradeOperation _operation) internal {
        vm.prank(coordinator);
        coreExecutor.beginOperation(_operation);
    }

    // ─────────────────────────── the owner path ───────────────────────────

    function test_applyL1Upgrade_upgradesChangedProxiesOnly() public {
        _applyL1Upgrade();

        assertEq(_liveImpl(bridgehubProxy), address(implNew), "changed implementation must be swapped");
        assertEq(
            _liveImpl(messageRootProxy),
            address(implOld),
            "proxy already pointing at the pinned implementation must be skipped"
        );
    }

    function test_applyL1Upgrade_isIdempotent() public {
        _applyL1Upgrade();
        // Second run: Bridgehub's proxy now already points at the pinned implementation, so the
        // live comparison skips everything and the call succeeds without effect.
        _applyL1Upgrade();

        assertEq(_liveImpl(bridgehubProxy), address(implNew), "implementation must stay at the pinned value");
    }

    function test_applyL1Upgrade_runsFixedInitializeUpgradeExactlyOnce() public {
        // Bridgehub moves to an implementation that must reinitialize. The row carries only a
        // BOOLEAN — no calldata, no data: the executor invokes the fixed, argument-less
        // selector atomically with the swap, and everything the reinitializer needs lives in
        // the implementation's own audited code.
        MockProxyUpgradeInitImpl initImpl = new MockProxyUpgradeInitImpl();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = ProxyUpgradeRow({
            proxy: address(bridgehubProxy),
            expectedOldImpl: address(implOld),
            implNew: PinnedContract({addr: address(initImpl), codehash: address(initImpl).codehash}),
            callInitializeUpgrade: true,
            admin: ProxyAdmin(address(0))
        });
        // Same audited bytecode as the fixture registry (no immutables), so the executor's
        // codehash pin covers this instance too.
        ICoreRegistry initRegistry = _deployRegistry(rows);

        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(initRegistry);

        assertEq(_liveImpl(bridgehubProxy), address(initImpl), "implementation must be swapped");
        assertEq(
            MockProxyUpgradeInitImpl(address(bridgehubProxy)).initializeUpgradeCalls(),
            1,
            "the fixed reinitializer must run exactly once, atomically with the swap"
        );
    }

    function test_revertWhen_applyL1UpgradeByStranger() public {
        // Not even the CTM-scope governor may drive the ecosystem executor: authority domains
        // are separate, and the entrypoint admits the owner or the coordinator only.
        address ctmGovernor = makeAddr("ctmGovernor");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ctmGovernor));
        vm.prank(ctmGovernor);
        coreExecutor.applyL1Upgrade(coreRegistry);
        assertEq(_liveImpl(bridgehubProxy), address(implOld));
    }

    function test_revertWhen_registryIsNotTheAuditedCode() public {
        // Type provenance is a codehash check: an object that does not run the audited
        // `CoreRegistry` code is rejected before any row is read, whatever it claims to be.
        NotACoreRegistry impostor = new NotACoreRegistry();

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(impostor),
                coreRegistryCodehash,
                address(impostor).codehash
            )
        );
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(ICoreRegistry(address(impostor)));
    }

    function test_revertWhen_replayingStaleRegistryWouldDowngrade() public {
        _applyL1Upgrade();

        // A LATER upgrade moves Bridgehub further (freshest impl), then the ORIGINAL registry is
        // replayed: the proxy is at neither that registry's source nor its target, so the replay
        // must revert instead of silently downgrading.
        DummyImplA implNewer = new DummyImplA();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implNew), address(implNewer));
        ICoreRegistry laterRegistry = _deployRegistry(rows);
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(laterRegistry);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(implOld),
                address(implNewer)
            )
        );
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(coreRegistry);
    }

    // ─────────────────────────── coordinator binding ───────────────────────────

    function test_setCoordinator_rebindsAndEmits() public {
        address successor = makeAddr("successor");
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.CoordinatorChanged(coordinator, successor);
        vm.prank(ecosystemGovernor);
        coreExecutor.setCoordinator(successor);
        assertEq(coreExecutor.coordinator(), successor, "the binding must be recorded");

        // The old coordinator has lost its standing.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, coordinator));
        vm.prank(coordinator);
        coreExecutor.beginOperation(operation);
    }

    function test_revertWhen_setCoordinatorByStranger() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        coreExecutor.setCoordinator(makeAddr("successor"));
        assertEq(coreExecutor.coordinator(), coordinator);
    }

    /// @dev One operation is prepared, executed and completed by one coordinator.
    function test_revertWhen_setCoordinatorWhileReserved() public {
        _reserve(operation);
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(operation)));
        vm.prank(ecosystemGovernor);
        coreExecutor.setCoordinator(makeAddr("successor"));
        assertEq(coreExecutor.coordinator(), coordinator, "a reserved executor keeps its coordinator");
    }

    // ─────────────────────────── the reservation protocol ───────────────────────────

    function test_beginOperation_reservesTheRegistryTheOperationNames() public {
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.OperationReserved(address(operation), address(coreRegistry));
        _reserve(operation);

        assertEq(address(coreExecutor.activeOperation()), address(operation), "the operation must be recorded");
        assertEq(
            address(coreExecutor.reservedCoreRegistry()),
            address(coreRegistry),
            "the reserved leg is the operation's registry"
        );
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "reserving applies nothing");
    }

    function test_revertWhen_beginOperationByNonCoordinator() public {
        // The owner included: reservations are the coordinator's, and only the coordinator's.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ecosystemGovernor));
        vm.prank(ecosystemGovernor);
        coreExecutor.beginOperation(operation);
        assertEq(address(coreExecutor.activeOperation()), address(0));
    }

    function test_revertWhen_beginOperationWhileReserved() public {
        _reserve(operation);
        IEcosystemUpgradeOperation other = _operationNaming(address(coreRegistry));
        vm.expectRevert(abi.encodeWithSelector(UpgradeLifecycleBusy.selector, address(operation)));
        vm.prank(coordinator);
        coreExecutor.beginOperation(other);
        assertEq(address(coreExecutor.activeOperation()), address(operation), "the first reservation stands");
    }

    function test_revertWhen_beginOperationWithNonGenuineRegistry() public {
        // The operation names whatever address it is given; the reservation is where the leg's
        // provenance is checked — before anything is paused or applied anywhere.
        NotACoreRegistry impostor = new NotACoreRegistry();
        IEcosystemUpgradeOperation misnamed = _operationNaming(address(impostor));
        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(impostor),
                coreRegistryCodehash,
                address(impostor).codehash
            )
        );
        vm.prank(coordinator);
        coreExecutor.beginOperation(misnamed);
        assertEq(address(coreExecutor.activeOperation()), address(0), "a refused leg occupies nothing");
    }

    /// @dev An operation without an ecosystem leg has nothing to reserve here; the coordinator
    ///      never calls in for one, and a raw call gets a clear refusal.
    function test_revertWhen_beginOperationWithoutACoreLeg() public {
        IEcosystemUpgradeOperation ctmOnly = _operationNaming(address(0));
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(coordinator);
        coreExecutor.beginOperation(ctmOnly);
    }

    function test_coordinatorAppliesTheReservedRegistry() public {
        _reserve(operation);

        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.L1UpgradeApplied(address(coreRegistry));
        vm.prank(coordinator);
        coreExecutor.applyL1Upgrade(coreRegistry);

        assertEq(_liveImpl(bridgehubProxy), address(implNew), "the reserved leg must be applied");
        assertEq(address(coreExecutor.activeOperation()), address(operation), "applying does not release");
    }

    /// @dev The coordinator may apply exactly the leg the operation names — a coordinator bug (or
    ///      a raw call through its escape hatch) naming another registry gets nothing.
    function test_revertWhen_coordinatorAppliesAnUnreservedRegistry() public {
        _reserve(operation);
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(messageRootProxy), address(implOld), address(implNew));
        ICoreRegistry otherRegistry = _deployRegistry(rows);

        vm.expectRevert(abi.encodeWithSelector(LegNotReserved.selector, address(otherRegistry), address(coreRegistry)));
        vm.prank(coordinator);
        coreExecutor.applyL1Upgrade(otherRegistry);
        assertEq(_liveImpl(messageRootProxy), address(implOld), "an unreserved leg must not be applied");
    }

    function test_revertWhen_coordinatorAppliesWithoutAReservation() public {
        vm.expectRevert(abi.encodeWithSelector(LegNotReserved.selector, address(coreRegistry), address(0)));
        vm.prank(coordinator);
        coreExecutor.applyL1Upgrade(coreRegistry);
        assertEq(_liveImpl(bridgehubProxy), address(implOld));
    }

    /// @dev The owner path is unaffected by reservations: recovery and the bootstrap edge do not
    ///      go through the coordinator.
    function test_ownerAppliesDirectlyWhileReserved() public {
        _reserve(operation);
        _applyL1Upgrade();
        assertEq(_liveImpl(bridgehubProxy), address(implNew));
        assertEq(address(coreExecutor.activeOperation()), address(operation), "the reservation is untouched");
    }

    /// @dev Completion is the domain's own verification: the reservation is released only once the
    ///      reserved registry is applied.
    function test_completeOperation_requiresTheRegistryAppliedThenReleases() public {
        _reserve(operation);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(implNew),
                address(implOld)
            )
        );
        vm.prank(coordinator);
        coreExecutor.completeOperation();
        assertEq(address(coreExecutor.activeOperation()), address(operation), "a refused completion keeps the slot");

        vm.prank(coordinator);
        coreExecutor.applyL1Upgrade(coreRegistry);
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.OperationCompleted(address(operation));
        vm.prank(coordinator);
        coreExecutor.completeOperation();

        assertEq(address(coreExecutor.activeOperation()), address(0), "the operation must be cleared");
        assertEq(address(coreExecutor.reservedCoreRegistry()), address(0), "nothing stays reserved");
        // Free again: the next operation reserves normally.
        IEcosystemUpgradeOperation next = _operationNaming(address(coreRegistry));
        vm.prank(coordinator);
        coreExecutor.beginOperation(next);
        assertEq(address(coreExecutor.activeOperation()), address(next));
    }

    function test_abandonOperation_releasesWithoutVerifying() public {
        _reserve(operation);

        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit CoreUpgradeExecutor.OperationAbandoned(address(operation));
        vm.prank(coordinator);
        coreExecutor.abandonOperation();

        assertEq(address(coreExecutor.activeOperation()), address(0), "the operation must be cleared");
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "abandoning applies nothing");
    }

    /// @dev The callbacks act on the executor's own reservation; a free executor has none, which
    ///      is the state the removed operation argument used to be checked against.
    function test_revertWhen_completeOrAbandonWithNothingReserved() public {
        vm.startPrank(coordinator);
        vm.expectRevert(NoPendingOperation.selector);
        coreExecutor.completeOperation();
        vm.expectRevert(NoPendingOperation.selector);
        coreExecutor.abandonOperation();
        vm.stopPrank();
        assertEq(address(coreExecutor.activeOperation()), address(0), "nothing may become reserved");
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "and nothing may be applied");
    }

    function test_revertWhen_completeOrAbandonByNonCoordinator() public {
        _reserve(operation);
        vm.startPrank(ecosystemGovernor);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ecosystemGovernor));
        coreExecutor.completeOperation();
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ecosystemGovernor));
        coreExecutor.abandonOperation();
        vm.stopPrank();
        assertEq(address(coreExecutor.activeOperation()), address(operation));
    }

    // ─────────────────────────── post-state verification ───────────────────────────

    function test_validateUpgradeApplied_revertsBeforeAndPassesAfterApply() public {
        // Before the upgrade, the bridgehub row's proxy still points at the old implementation.
        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(implNew),
                address(implOld)
            )
        );
        coreExecutor.validateUpgradeApplied(coreRegistry);

        _applyL1Upgrade();

        // A view over live state — anyone may run the post-state check.
        vm.prank(makeAddr("stranger"));
        coreExecutor.validateUpgradeApplied(coreRegistry);
    }

    function test_revertWhen_validateUpgradeAppliedAgainstNonGenuineRegistry() public {
        // The check reads rows from the registry, so it enforces the same code provenance as the
        // apply path — an impostor is rejected before any row is trusted.
        _applyL1Upgrade();
        NotACoreRegistry impostor = new NotACoreRegistry();

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(impostor),
                coreRegistryCodehash,
                address(impostor).codehash
            )
        );
        coreExecutor.validateUpgradeApplied(ICoreRegistry(address(impostor)));
    }

    function test_manifestHashCommitsToTheRows() public {
        // Provenance pins the CODE; the manifest hash is what distinguishes two instances of it.
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        ICoreRegistry first = _deployRegistry(rows);
        assertEq(
            first.manifestHash(),
            _deployRegistry(rows).manifestHash(),
            "same manifest must produce the same commitment"
        );

        rows[0] = _row(address(messageRootProxy), address(implOld), address(implNew));
        assertTrue(_deployRegistry(rows).manifestHash() != first.manifestHash(), "a different manifest must differ");
    }
}

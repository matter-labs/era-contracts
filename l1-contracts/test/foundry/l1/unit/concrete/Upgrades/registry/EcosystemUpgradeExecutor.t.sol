// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/objects/ICoreRegistry.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {
    EcosystemLegNotNamedByTransition,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch,
    Unauthorized,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
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

/// @dev Test double of a CTM executor's lifecycle surface — the ONLY thing the ecosystem
///      executor reads from an authorized caller (`ICTMUpgradeExecutor.pendingTransition()`),
///      plus a passthrough so the double is the `msg.sender` of `applyL1Upgrade`.
///      MOCKED deliberately: this suite isolates the ecosystem executor's authority rule from the
///      CTM lifecycle. The same rule is driven end to end with the real `CTMUpgradeExecutor`
///      (stage 0 recording the transition, stage 1 applying the leg) in CTMUpgradeLifecycle.t.sol.
contract StubCTMExecutor {
    ICTMTransition public pendingTransition;

    function setPendingTransition(ICTMTransition _transition) external {
        pendingTransition = _transition;
    }

    function applyEcosystemLeg(EcosystemUpgradeExecutor _executor, ICoreRegistry _coreRegistry) external {
        _executor.applyL1Upgrade(_coreRegistry);
    }
}

/// @dev The one transition getter the authority rule reads: which registry the leg is for.
contract StubTransition {
    address public coreRegistry;

    constructor(address _coreRegistry) {
        coreRegistry = _coreRegistry;
    }
}

/// @notice Tests the ecosystem-scoped upgrade executor. Deliberately owned by a DIFFERENT
///         governance address than the CTM-scoped executor in CTMUpgradeExecutor.t.sol: the two
///         authority domains are separable — each scope runs its own executor with its own owner,
///         and neither needs the other scope's registry.
/// @dev Registries are REAL, factory-deployed `CoreRegistry` instances: the executor enforces
///      factory provenance, so a mutable test double (or any hand-rolled `ICoreRegistry`
///      implementation) is rejected by design — which this suite also asserts.
contract EcosystemUpgradeExecutorTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal ecosystemGovernor = makeAddr("ecosystemGovernor");

    EcosystemUpgradeExecutor internal ecosystemExecutor;
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

        // The ecosystem executor is BOUND to (and owns) one immutable ecosystem ProxyAdmin and
        // pins the audited `CoreRegistry` codehash, mirroring the production ownership chain (and
        // nothing else — no CTM authority).
        ecosystemExecutor = new EcosystemUpgradeExecutor(ecosystemGovernor, proxyAdmin, coreRegistryCodehash);
        proxyAdmin.transferOwnership(address(ecosystemExecutor));
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
                callInitializeUpgrade: false
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

    function _applyL1Upgrade() internal {
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(coreRegistry);
    }

    function test_applyL1Upgrade_upgradesChangedProxiesOnly() public {
        _applyL1Upgrade();

        assertEq(
            address(uint160(uint256(vm.load(address(bridgehubProxy), EIP1967_IMPL_SLOT)))),
            address(implNew),
            "changed implementation must be swapped"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(messageRootProxy), EIP1967_IMPL_SLOT)))),
            address(implOld),
            "proxy already pointing at the pinned implementation must be skipped"
        );
    }

    function test_applyL1Upgrade_isIdempotent() public {
        _applyL1Upgrade();
        // Second run: Bridgehub's proxy now already points at the pinned implementation, so the
        // live comparison skips everything and the call succeeds without effect.
        _applyL1Upgrade();

        assertEq(
            address(uint160(uint256(vm.load(address(bridgehubProxy), EIP1967_IMPL_SLOT)))),
            address(implNew),
            "implementation must stay at the pinned value after a replay"
        );
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
            callInitializeUpgrade: true
        });
        // Same audited bytecode as the fixture registry (no immutables), so the executor's
        // codehash pin covers this instance too.
        ICoreRegistry initRegistry = _deployRegistry(rows);

        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(initRegistry);

        assertEq(
            address(uint160(uint256(vm.load(address(bridgehubProxy), EIP1967_IMPL_SLOT)))),
            address(initImpl),
            "implementation must be swapped"
        );
        assertEq(
            MockProxyUpgradeInitImpl(address(bridgehubProxy)).initializeUpgradeCalls(),
            1,
            "the fixed reinitializer must run exactly once, atomically with the swap"
        );
    }

    function test_revertWhen_executorCalledByNonEcosystemGovernance() public {
        // Not even the CTM-scope governor may drive the ecosystem executor: authority domains
        // are separate, and the entrypoint admits the owner or an explicitly authorized CTM
        // executor only (no arbitrary-delegatecall surface).
        address ctmGovernor = makeAddr("ctmGovernor");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ctmGovernor));
        vm.prank(ctmGovernor);
        ecosystemExecutor.applyL1Upgrade(coreRegistry);
    }

    // ─────────────────────────── CTM executor authorization ───────────────────────────

    function test_setCTMExecutorAuthorization_grantsAndRevokes() public {
        address ctmExecutor = makeAddr("ctmExecutor");
        assertFalse(ecosystemExecutor.isAuthorizedCTMExecutor(ctmExecutor));

        vm.expectEmit(true, true, true, true, address(ecosystemExecutor));
        emit EcosystemUpgradeExecutor.CTMExecutorAuthorizationSet(ctmExecutor, true);
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(ctmExecutor, true);
        assertTrue(ecosystemExecutor.isAuthorizedCTMExecutor(ctmExecutor), "authorization must be recorded");

        vm.expectEmit(true, true, true, true, address(ecosystemExecutor));
        emit EcosystemUpgradeExecutor.CTMExecutorAuthorizationSet(ctmExecutor, false);
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(ctmExecutor, false);
        assertFalse(ecosystemExecutor.isAuthorizedCTMExecutor(ctmExecutor), "revocation must be recorded");
    }

    function test_revertWhen_setCTMExecutorAuthorizationByStranger() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ecosystemExecutor.setCTMExecutorAuthorization(makeAddr("ctmExecutor"), true);
    }

    function test_revertWhen_setCTMExecutorAuthorizationForZeroAddress() public {
        vm.expectRevert(ZeroAddress.selector);
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(0), true);
    }

    /// @dev The authority rule for a non-owner caller: authorized, AND the registry is the one its
    ///      pending transition names. See the mock note on `StubCTMExecutor`.
    function test_authorizedCTMExecutorAppliesTheRegistryItsPendingTransitionNames() public {
        StubCTMExecutor ctmExecutor = new StubCTMExecutor();
        ctmExecutor.setPendingTransition(ICTMTransition(address(new StubTransition(address(coreRegistry)))));
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), true);

        vm.expectEmit(true, true, true, true, address(ecosystemExecutor));
        emit EcosystemUpgradeExecutor.L1UpgradeApplied(address(coreRegistry));
        ctmExecutor.applyEcosystemLeg(ecosystemExecutor, coreRegistry);

        assertEq(
            address(uint160(uint256(vm.load(address(bridgehubProxy), EIP1967_IMPL_SLOT)))),
            address(implNew),
            "the named leg must be applied through the bound admin"
        );
    }

    function test_revertWhen_authorizedCTMExecutorNamesAnotherRegistry() public {
        StubCTMExecutor ctmExecutor = new StubCTMExecutor();
        StubTransition pending = new StubTransition(address(coreRegistry));
        ctmExecutor.setPendingTransition(ICTMTransition(address(pending)));
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), true);

        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(messageRootProxy), address(implOld), address(implNew));
        ICoreRegistry otherRegistry = _deployRegistry(rows);

        vm.expectRevert(
            abi.encodeWithSelector(EcosystemLegNotNamedByTransition.selector, address(pending), address(otherRegistry))
        );
        ctmExecutor.applyEcosystemLeg(ecosystemExecutor, otherRegistry);
        assertEq(
            address(uint160(uint256(vm.load(address(messageRootProxy), EIP1967_IMPL_SLOT)))),
            address(implOld),
            "an unnamed leg must not be applied"
        );
    }

    function test_revertWhen_authorizedCTMExecutorHasNoPendingTransition() public {
        StubCTMExecutor ctmExecutor = new StubCTMExecutor();
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), true);

        vm.expectRevert(
            abi.encodeWithSelector(EcosystemLegNotNamedByTransition.selector, address(0), address(coreRegistry))
        );
        ctmExecutor.applyEcosystemLeg(ecosystemExecutor, coreRegistry);
    }

    function test_revertWhen_revokedCTMExecutorAppliesALeg() public {
        StubCTMExecutor ctmExecutor = new StubCTMExecutor();
        ctmExecutor.setPendingTransition(ICTMTransition(address(new StubTransition(address(coreRegistry)))));
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), true);
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), false);

        // The pending transition names the registry, but the authorization is gone.
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, address(ctmExecutor)));
        ctmExecutor.applyEcosystemLeg(ecosystemExecutor, coreRegistry);
        assertEq(address(uint160(uint256(vm.load(address(bridgehubProxy), EIP1967_IMPL_SLOT)))), address(implOld));
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
        ecosystemExecutor.validateUpgradeApplied(coreRegistry);

        _applyL1Upgrade();

        // A view over live state — anyone may run the post-state check.
        vm.prank(makeAddr("stranger"));
        ecosystemExecutor.validateUpgradeApplied(coreRegistry);
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
        ecosystemExecutor.validateUpgradeApplied(ICoreRegistry(address(impostor)));
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
        ecosystemExecutor.applyL1Upgrade(ICoreRegistry(address(impostor)));
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
        ecosystemExecutor.applyL1Upgrade(laterRegistry);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(implOld),
                address(implNewer)
            )
        );
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(coreRegistry);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ICoreUpgradeExecutor} from "contracts/upgrades/registry/executors/ICoreUpgradeExecutor.sol";
import {IDomainUpgradeExecutor} from "contracts/upgrades/registry/executors/IDomainUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {CoreTransition} from "contracts/upgrades/registry/objects/CoreTransition.sol";
import {ICoreTransition} from "contracts/upgrades/registry/objects/ICoreTransition.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {ProxyUpgradeRowMismatch, RegistryTargetHasNoCode, Unauthorized} from "contracts/common/L1ContractErrors.sol";
import {
    CoreTransitionManifest,
    OperationManifest,
    ProxyUpgradeRow
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract
} from "../../../../../../../contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

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
///         edge applies a registry) and the coordinator path (`applyOperation`). Deliberately owned
///         by a DIFFERENT governance address than the CTM-scoped executor in
///         CTMUpgradeExecutor.t.sol: the two authority domains are separable.
/// @dev Registries are REAL, write-once `CoreTransition` instances rather than mutable test
///      doubles: the rows the executor applies are the rows a governance-reviewed object serves.
/// @dev The COORDINATOR IS A PLAIN ADDRESS here, pranked: this suite isolates the executor's own
///      rules (who may apply, and what) from the coordinator's. Each call hands in a manifest the
///      way the coordinator does; the real coordinator drives the same callback end to end in
///      OperationExecution.t.sol and EcosystemUpgradeCoordination.t.sol.
contract CoreUpgradeExecutorTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal ecosystemGovernor = makeAddr("ecosystemGovernor");
    address internal coordinator = makeAddr("coordinator");

    CoreUpgradeExecutor internal coreExecutor;
    ICoreTransition internal coreTransition;
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
        messageRootProxy = new TransparentUpgradeableProxy(address(implNew), address(proxyAdmin), hex"");

        // Both rows are source-checked edges (old -> new). MessageRoot already runs its target, so
        // the executor's live comparison must skip it. Every row must be a real, unique edge — a
        // placeholder (all-zero) or self-edge row is rejected at the registry boundary.
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](2);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        rows[1] = _row(address(messageRootProxy), address(implOld), address(implNew));
        coreTransition = _deployRegistry(rows);

        // The executor is BOUND to (and owns) one immutable ecosystem ProxyAdmin, mirroring the
        // production ownership chain; the owner then points it at the coordinator (the v35
        // bootstrap's binding).
        coreExecutor = new CoreUpgradeExecutor(ecosystemGovernor, proxyAdmin);
        proxyAdmin.transferOwnership(address(coreExecutor));
        vm.prank(ecosystemGovernor);
        coreExecutor.setCoordinator(coordinator);
    }

    /// @dev A manifest whose ecosystem leg is `_coreTransition` (zero for none). The CTM side is a
    ///      labelled stand-in — the core executor reads only its own leg.
    function _manifestNaming(address _coreTransition) internal returns (OperationManifest memory) {
        return
            OperationManifest({
                coreTransition: _coreTransition,
                ctmInfrastructure: new ProxyUpgradeRow[](CTM_CONTRACT_COUNT),
                ctmTransition: makeAddr("transition")
            });
    }

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

    /// @dev The registry takes the enum-indexed inventory; these tests exercise row semantics
    ///      with two synthetic proxies, so they occupy the `L1Bridgehub` and `L1MessageRoot`
    ///      slots (the slot is a label — the row's own proxy address is its identity).
    function _deployRegistry(ProxyUpgradeRow[] memory _rows) internal returns (ICoreTransition) {
        CoreTransitionManifest memory manifest;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        if (_rows.length > 0) {
            manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = _rows[0];
        }
        if (_rows.length > 1) {
            manifest.proxyUpgrades[uint256(L1EcosystemContract.L1MessageRoot)] = _rows[1];
        }
        return ICoreTransition(address(new CoreTransition(manifest)));
    }

    function _liveImpl(TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(_proxy), EIP1967_IMPL_SLOT))));
    }

    function _applyL1Upgrade() internal {
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(coreTransition);
    }

    // ─────────────────────────── the owner path ───────────────────────────

    function test_applyL1Upgrade_upgradesChangedProxiesOnly() public {
        vm.recordLogs();
        _applyL1Upgrade();
        Vm.Log[] memory logs = vm.getRecordedLogs();

        assertEq(_liveImpl(bridgehubProxy), address(implNew), "changed implementation must be swapped");
        assertEq(_liveImpl(messageRootProxy), address(implNew), "proxy already at its target must stay there");
        uint256 upgraded = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (
                logs[i].topics.length > 0 &&
                logs[i].topics[0] == ProxyUpgradeRowLib.ProxyImplementationUpgraded.selector
            ) {
                assertEq(
                    logs[i].topics[1],
                    bytes32(uint256(uint160(address(bridgehubProxy)))),
                    "only the changed proxy is upgraded"
                );
                ++upgraded;
            }
        }
        assertEq(upgraded, 1, "the proxy already at its target must be skipped");
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
            implNew: address(initImpl),
            callInitializeUpgrade: true
        });
        ICoreTransition initRegistry = _deployRegistry(rows);

        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(initRegistry);

        assertEq(_liveImpl(bridgehubProxy), address(initImpl), "implementation must be swapped");
        assertEq(
            MockProxyUpgradeInitImpl(address(bridgehubProxy)).initializeUpgradeCalls(),
            1,
            "the fixed reinitializer must run exactly once, atomically with the swap"
        );
    }

    function test_revertWhen_applyL1UpgradeByStrangerOrCoordinator() public {
        // Not even the CTM-scope governor may drive the ecosystem executor: authority domains
        // are separate, and the owner path admits the owner only — the coordinator applies
        // through `applyOperation`.
        address ctmGovernor = makeAddr("ctmGovernor");
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ctmGovernor);
        coreExecutor.applyL1Upgrade(coreTransition);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(coordinator);
        coreExecutor.applyL1Upgrade(coreTransition);
        assertEq(_liveImpl(bridgehubProxy), address(implOld));
    }

    /// @dev Retargeted from the removed codehash anchor to the check that still guards this
    ///      entrypoint: the registry must be DEPLOYED. A call into a codeless address succeeds
    ///      silently, so without it an undeployed registry turns the apply into a reported no-op.
    function test_revertWhen_registryIsNotDeployed() public {
        address codeless = makeAddr("codelessRegistry");

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(ICoreTransition(codeless));
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "a refused registry applies nothing");
    }

    function test_revertWhen_replayingStaleRegistryWouldDowngrade() public {
        _applyL1Upgrade();

        // A LATER upgrade moves Bridgehub further (freshest impl), then the ORIGINAL registry is
        // replayed: the proxy is at neither that registry's source nor its target, so the replay
        // must revert instead of silently downgrading.
        DummyImplA implNewer = new DummyImplA();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implNew), address(implNewer));
        ICoreTransition laterRegistry = _deployRegistry(rows);
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
        coreExecutor.applyL1Upgrade(coreTransition);
    }

    // ─────────────────────────── coordinator binding ───────────────────────────

    function test_setCoordinator_rebindsAndEmits() public {
        address successor = makeAddr("successor");
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit IDomainUpgradeExecutor.CoordinatorChanged(coordinator, successor);
        vm.prank(ecosystemGovernor);
        coreExecutor.setCoordinator(successor);
        assertEq(coreExecutor.coordinator(), successor, "the binding must be recorded");

        // The old coordinator has lost its standing.
        OperationManifest memory manifest = _manifestNaming(address(coreTransition));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, coordinator));
        vm.prank(coordinator);
        coreExecutor.applyOperation(manifest);
        assertEq(_liveImpl(bridgehubProxy), address(implOld));
    }

    function test_revertWhen_setCoordinatorByStranger() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        coreExecutor.setCoordinator(makeAddr("successor"));
        assertEq(coreExecutor.coordinator(), coordinator);
    }

    // ─────────────────────────── the coordinator path ───────────────────────────

    function test_coordinatorAppliesTheManifestsCoreTransition() public {
        OperationManifest memory manifest = _manifestNaming(address(coreTransition));
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ICoreUpgradeExecutor.L1UpgradeApplied(address(coreTransition));
        vm.prank(coordinator);
        coreExecutor.applyOperation(manifest);

        assertEq(_liveImpl(bridgehubProxy), address(implNew), "the manifest's leg must be applied");
        assertEq(_liveImpl(messageRootProxy), address(implNew), "a row already at its target stays there");
    }

    function test_revertWhen_applyOperationByNonCoordinator() public {
        // The owner included: the coordinator path is the coordinator's, and only the coordinator's.
        OperationManifest memory manifest = _manifestNaming(address(coreTransition));
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, ecosystemGovernor));
        vm.prank(ecosystemGovernor);
        coreExecutor.applyOperation(manifest);
        address stranger = makeAddr("stranger");
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, stranger));
        vm.prank(stranger);
        coreExecutor.applyOperation(manifest);
        assertEq(_liveImpl(bridgehubProxy), address(implOld));
    }

    /// @dev The leg must be deployed: a call into a codeless address succeeds silently, so without
    ///      the check the leg would report itself applied over nothing. A manifest without a core
    ///      leg is never handed to this executor; a raw call names the zero address and is refused
    ///      the same way.
    function test_revertWhen_applyOperationWithAnUndeployedCoreTransition() public {
        address codeless = makeAddr("codelessRegistry");
        OperationManifest memory misnamed = _manifestNaming(codeless);
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        vm.prank(coordinator);
        coreExecutor.applyOperation(misnamed);

        OperationManifest memory ctmOnly = _manifestNaming(address(0));
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, address(0)));
        vm.prank(coordinator);
        coreExecutor.applyOperation(ctmOnly);
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "a refused leg applies nothing");
    }

    function test_manifestHashCommitsToTheRows() public {
        // The manifest hash is what distinguishes two instances of the same audited code.
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        ICoreTransition first = _deployRegistry(rows);
        assertEq(
            first.manifestHash(),
            _deployRegistry(rows).manifestHash(),
            "same manifest must produce the same commitment"
        );

        rows[0] = _row(address(messageRootProxy), address(implOld), address(implNew));
        assertTrue(_deployRegistry(rows).manifestHash() != first.manifestHash(), "a different manifest must differ");
    }
}

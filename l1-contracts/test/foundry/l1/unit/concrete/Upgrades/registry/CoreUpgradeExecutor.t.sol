// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test, Vm} from "forge-std/Test.sol";
import {Ownable} from "@openzeppelin/contracts-v4/access/Ownable.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {Call} from "contracts/governance/Common.sol";
import {ICoreUpgradeExecutor} from "contracts/upgrades/registry/executors/ICoreUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {ProxyUpgradeRowLib} from "contracts/upgrades/registry/libraries/ProxyUpgradeRowLib.sol";
import {
    ProxyUpgradeDomainMismatch,
    ProxyUpgradeRowMismatch,
    RegistryTargetHasNoCode,
    RenounceOwnershipDisabled,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    ProxyUpgradeDomain,
    ProxyUpgradeRow,
    ProxyUpgradeTransitionManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
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

contract DummyImplC {
    function version() external pure returns (uint256) {
        return 3;
    }
}

/// @dev Applies rows straight through `ProxyUpgradeRowLib.applyRows`, as the executors and the
///      bootstrap do. It reaches rows no `ProxyUpgradeTransition` can pin (its constructor refuses
///      them), so the apply-time semantics of a malformed row stay pinned.
contract RowApplier {
    function applyRows(ProxyAdmin _admin, ProxyUpgradeRow[] memory _rows) external {
        ProxyUpgradeRowLib.applyRows(_admin, _rows);
    }
}

/// @notice Tests the ecosystem-domain executor on its own: `applyL1Upgrade` (the bootstrap edge's
///         core leg and every later upgrade's). Deliberately owned by a DIFFERENT governance address
///         than the CTM-scoped executor in CTMUpgradeExecutor.t.sol: the two authority domains are
///         separable. Multi-leg governance bundles are UpgradeBundleExecution.t.sol.
/// @dev Transitions are REAL, write-once `ProxyUpgradeTransition` instances rather than mutable test
///      doubles: the rows the executor applies are the rows a governance-reviewed object serves.
contract CoreUpgradeExecutorTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal ecosystemGovernor = makeAddr("ecosystemGovernor");

    CoreUpgradeExecutor internal coreExecutor;
    IProxyUpgradeTransition internal coreTransition;
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
        // production ownership chain.
        coreExecutor = new CoreUpgradeExecutor(ecosystemGovernor, proxyAdmin);
        proxyAdmin.transferOwnership(address(coreExecutor));
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

    /// @dev The transition takes the enum-indexed inventory; these tests exercise row semantics
    ///      with two synthetic proxies, so they occupy the `L1Bridgehub` and `L1MessageRoot`
    ///      slots (the slot is a label — the row's own proxy address is its identity).
    function _deployRegistry(ProxyUpgradeRow[] memory _rows) internal returns (IProxyUpgradeTransition) {
        ProxyUpgradeTransitionManifest memory manifest;
        manifest.domain = ProxyUpgradeDomain.Core;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        if (_rows.length > 0) {
            manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = _rows[0];
        }
        if (_rows.length > 1) {
            manifest.proxyUpgrades[uint256(L1EcosystemContract.L1MessageRoot)] = _rows[1];
        }
        return new ProxyUpgradeTransition(manifest);
    }

    function _liveImpl(TransparentUpgradeableProxy _proxy) internal view returns (address) {
        return address(uint160(uint256(vm.load(address(_proxy), EIP1967_IMPL_SLOT))));
    }

    function _applyL1Upgrade() internal {
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(coreTransition);
    }

    /// @dev Governance hands the ecosystem ProxyAdmin from the executor to a `RowApplier` through
    ///      the executor's `forward`.
    function _rowApplier() internal returns (RowApplier applier) {
        applier = new RowApplier();
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(proxyAdmin),
            value: 0,
            data: abi.encodeCall(Ownable.transferOwnership, (address(applier)))
        });
        vm.prank(ecosystemGovernor);
        coreExecutor.forward(calls);
    }

    // ─────────────────────────── the owner path ───────────────────────────

    function test_applyL1Upgrade_upgradesChangedProxiesOnly() public {
        vm.expectEmit(true, true, true, true, address(coreExecutor));
        emit ICoreUpgradeExecutor.L1UpgradeApplied(address(coreTransition));
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
        IProxyUpgradeTransition initRegistry = _deployRegistry(rows);

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
        // are separate, and the entrypoint admits the owner only.
        address ctmGovernor = makeAddr("ctmGovernor");
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(ctmGovernor);
        coreExecutor.applyL1Upgrade(coreTransition);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        coreExecutor.applyL1Upgrade(coreTransition);
        assertEq(_liveImpl(bridgehubProxy), address(implOld));
    }

    /// @dev A CTM-domain object never applies through the ecosystem admin, even when its rows would
    ///      resolve there: the domain is the object's pinned statement of which executor applies it.
    function test_revertWhen_applyL1UpgradeWithACTMDomainTransition() public {
        ProxyUpgradeTransitionManifest memory manifest;
        manifest.domain = ProxyUpgradeDomain.CTM;
        manifest.proxyUpgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(
            address(bridgehubProxy),
            address(implOld),
            address(implNew)
        );
        ProxyUpgradeTransition ctmDomain = new ProxyUpgradeTransition(manifest);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeDomainMismatch.selector,
                uint8(ProxyUpgradeDomain.Core),
                uint8(ProxyUpgradeDomain.CTM)
            )
        );
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(ctmDomain);
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "a refused transition applies nothing");
    }

    /// @dev Retargeted from the removed codehash anchor to the check that still guards this
    ///      entrypoint: the registry must be DEPLOYED. A call into a codeless address succeeds
    ///      silently, so without it an undeployed registry turns the apply into a reported no-op.
    function test_revertWhen_registryIsNotDeployed() public {
        address codeless = makeAddr("codelessRegistry");

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        vm.prank(ecosystemGovernor);
        coreExecutor.applyL1Upgrade(IProxyUpgradeTransition(codeless));
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "a refused registry applies nothing");
    }

    /// @dev Every row's implementation is code-checked before the first swap.
    function test_revertWhen_aRowImplementationHasNoCode() public {
        vm.etch(address(implNew), "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, address(implNew)));
        _applyL1Upgrade();
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "nothing is applied");
    }

    function test_revertWhen_constructedOverAZeroProxyAdmin() public {
        vm.expectRevert(ZeroAddress.selector);
        new CoreUpgradeExecutor(ecosystemGovernor, ProxyAdmin(address(0)));
    }

    /// @dev An ownerless executor would strand the ProxyAdmin it holds.
    function test_revertWhen_renouncingOwnership() public {
        vm.prank(ecosystemGovernor);
        vm.expectRevert(RenounceOwnershipDisabled.selector);
        coreExecutor.renounceOwnership();
        assertEq(coreExecutor.owner(), ecosystemGovernor, "the owner is kept");
    }

    // ─────────────────────────── malformed rows, where they are applied ───────────────────────────
    // A `ProxyUpgradeTransition` refuses these rows at construction (`StorageRegistries.t.sol`), so
    // they are applied through `RowApplier`. These pin what each malformed row does on chain
    // regardless: it is skipped, or the whole application reverts.

    /// @dev Two rows chaining one proxy through two targets: the second swap lands, and the
    ///      post-pass refuses the first row ending off its target (objlib-48, boot-47).
    function test_revertWhen_aDuplicateProxyChainsThroughTwoTargets() public {
        RowApplier applier = _rowApplier();
        DummyImplC implNewer = new DummyImplC();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](2);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        rows[1] = _row(address(bridgehubProxy), address(implNew), address(implNewer));

        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(implNew),
                address(implNewer)
            )
        );
        applier.applyRows(proxyAdmin, rows);
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "nothing of the leg stands");
    }

    /// @dev Two rows departing one source toward different targets: the second finds the proxy at
    ///      the first's target.
    function test_revertWhen_aDuplicateProxyDepartsTowardTwoTargets() public {
        RowApplier applier = _rowApplier();
        DummyImplC implOther = new DummyImplC();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](2);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        rows[1] = _row(address(bridgehubProxy), address(implOld), address(implOther));

        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(implOld),
                address(implNew)
            )
        );
        applier.applyRows(proxyAdmin, rows);
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "nothing of the leg stands");
    }

    /// @dev The same row twice is idempotent: the second is skipped, and the post-pass holds.
    function test_anIdenticalDuplicateRowIsHarmless() public {
        RowApplier applier = _rowApplier();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](2);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        rows[1] = rows[0];

        vm.recordLogs();
        applier.applyRows(proxyAdmin, rows);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 swaps = 0;
        for (uint256 i = 0; i < logs.length; ++i) {
            if (logs[i].topics[0] == ProxyUpgradeRowLib.ProxyImplementationUpgraded.selector) {
                ++swaps;
            }
        }
        assertEq(swaps, 1, "the proxy is swapped once");
        assertEq(_liveImpl(bridgehubProxy), address(implNew));
    }

    /// @dev A self-edge (`implNew == expectedOldImpl`) never moves its proxy: skipped when the proxy
    ///      is there, refused otherwise (objlib-47).
    function test_aSelfEdgeRowNeverMovesItsProxy() public {
        RowApplier applier = _rowApplier();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implOld));
        applier.applyRows(proxyAdmin, rows);
        assertEq(_liveImpl(bridgehubProxy), address(implOld), "skipped");

        rows[0] = _row(address(bridgehubProxy), address(implNew), address(implNew));
        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(implNew),
                address(implOld)
            )
        );
        applier.applyRows(proxyAdmin, rows);
    }

    /// @dev A zero proxy cannot be read through the ProxyAdmin (objlib-44); a zero source never
    ///      matches a live implementation (objlib-45).
    function test_revertWhen_aRowHasAZeroField() public {
        RowApplier applier = _rowApplier();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(0), address(implOld), address(implNew));
        vm.expectRevert(bytes(""));
        applier.applyRows(proxyAdmin, rows);

        rows[0] = _row(address(bridgehubProxy), address(0), address(implNew));
        vm.expectRevert(
            abi.encodeWithSelector(
                ProxyUpgradeRowMismatch.selector,
                address(bridgehubProxy),
                address(0),
                address(implOld)
            )
        );
        applier.applyRows(proxyAdmin, rows);
        assertEq(_liveImpl(bridgehubProxy), address(implOld));
    }

    function test_revertWhen_replayingStaleRegistryWouldDowngrade() public {
        _applyL1Upgrade();

        // A LATER upgrade moves Bridgehub further (freshest impl), then the ORIGINAL registry is
        // replayed: the proxy is at neither that registry's source nor its target, so the replay
        // must revert instead of silently downgrading.
        DummyImplA implNewer = new DummyImplA();
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implNew), address(implNewer));
        IProxyUpgradeTransition laterRegistry = _deployRegistry(rows);
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

    function test_manifestHashCommitsToTheRows() public {
        // The manifest hash is what distinguishes two instances of the same audited code.
        ProxyUpgradeRow[] memory rows = new ProxyUpgradeRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        IProxyUpgradeTransition first = _deployRegistry(rows);
        assertEq(
            first.manifestHash(),
            _deployRegistry(rows).manifestHash(),
            "same manifest must produce the same commitment"
        );

        rows[0] = _row(address(messageRootProxy), address(implOld), address(implNew));
        assertTrue(_deployRegistry(rows).manifestHash() != first.manifestHash(), "a different manifest must differ");
    }
}

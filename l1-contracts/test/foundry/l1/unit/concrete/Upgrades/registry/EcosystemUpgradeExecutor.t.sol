// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/EcosystemUpgradeExecutor.sol";
import {CoreRegistry} from "contracts/upgrades/registry/CoreRegistry.sol";
import {CoreRegistryFactory} from "contracts/upgrades/registry/CTMRegistryFactory.sol";
import {ICoreRegistry, EcosystemContractRow} from "contracts/upgrades/registry/ICoreRegistry.sol";
import {EcosystemImplMismatch, NotFactoryDeployed} from "contracts/common/L1ContractErrors.sol";

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
    CoreRegistryFactory internal coreRegistryFactory;
    ICoreRegistry internal coreRegistry;
    ProxyAdmin internal proxyAdmin;

    DummyImplA internal implOld;
    DummyImplB internal implNew;
    TransparentUpgradeableProxy internal bridgehubProxy;
    TransparentUpgradeableProxy internal messageRootProxy;

    function setUp() public {
        implOld = new DummyImplA();
        implNew = new DummyImplB();

        // The ecosystem executor is BOUND to (and owns) one immutable ecosystem ProxyAdmin and
        // one immutable registry factory, mirroring the production ownership chain (and nothing
        // else — no CTM authority).
        proxyAdmin = new ProxyAdmin();
        coreRegistryFactory = new CoreRegistryFactory();
        ecosystemExecutor = new EcosystemUpgradeExecutor(
            ecosystemGovernor,
            makeAddr("breakGlass"),
            proxyAdmin,
            coreRegistryFactory
        );
        proxyAdmin.transferOwnership(address(ecosystemExecutor));
        bridgehubProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");
        messageRootProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");

        // Bridgehub is a full source-checked edge (old -> new); MessageRoot pins its live
        // implementation (the executor's live comparison must skip it). Every row must be a real,
        // unique edge — a placeholder (all-zero) row is rejected at the registry boundary.
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](2);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        rows[1] = _row(address(messageRootProxy), address(implOld), address(implOld));
        coreRegistry = _deployRegistry(rows);
    }

    function _row(
        address _proxy,
        address _expectedOldImpl,
        address _implNew
    ) internal view returns (EcosystemContractRow memory) {
        return
            EcosystemContractRow({
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: _implNew,
                implNewCodehash: _implNew.codehash
            });
    }

    /// @dev The production deployment surface: atomic deploy + initialize through the bound
    ///      factory, which is what makes the instance acceptable to the executor.
    function _deployRegistry(EcosystemContractRow[] memory _rows) internal returns (ICoreRegistry) {
        return
            ICoreRegistry(
                coreRegistryFactory.deployOrGetCoreRegistry(CoreRegistry.CoreRegistryManifest({contractRows: _rows}))
            );
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

    function test_revertWhen_executorCalledByNonEcosystemGovernance() public {
        // Not even the CTM-scope governor may drive the ecosystem executor: authority domains
        // are separate, and the entrypoint is owner-gated (no arbitrary-delegatecall surface).
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("ctmGovernor"));
        ecosystemExecutor.applyL1Upgrade(coreRegistry);
    }

    function test_revertWhen_registryNotFactoryDeployed() public {
        // A hand-deployed registry — genuine CoreRegistry code, correctly initialized, but NOT
        // deployed through the bound factory — must be rejected: factory provenance is what
        // turns "canonical write-once object" into an on-chain invariant.
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        CoreRegistry handDeployed = new CoreRegistry();
        handDeployed.initialize(CoreRegistry.CoreRegistryManifest({contractRows: rows}));

        vm.expectRevert(abi.encodeWithSelector(NotFactoryDeployed.selector, address(handDeployed)));
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(ICoreRegistry(address(handDeployed)));
    }

    function test_factoryDeployOrGetIsIdempotentPerManifest() public {
        // Same manifest -> the existing instance is returned (a same-manifest front-run merely
        // does the caller's work); a different manifest lands in a different instance.
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implOld), address(implNew));
        address first = address(_deployRegistry(rows));
        address second = address(_deployRegistry(rows));
        assertEq(first, second, "same manifest must resolve to the same instance");

        rows[0] = _row(address(messageRootProxy), address(implOld), address(implNew));
        assertTrue(address(_deployRegistry(rows)) != first, "a different manifest must land elsewhere");
    }

    function test_revertWhen_replayingStaleRegistryWouldDowngrade() public {
        _applyL1Upgrade();

        // A LATER upgrade moves Bridgehub further (freshest impl), then the ORIGINAL registry is
        // replayed: the proxy is at neither that registry's source nor its target, so the replay
        // must revert instead of silently downgrading.
        DummyImplA implNewer = new DummyImplA();
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](1);
        rows[0] = _row(address(bridgehubProxy), address(implNew), address(implNewer));
        ICoreRegistry laterRegistry = _deployRegistry(rows);
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(laterRegistry);

        vm.expectRevert(
            abi.encodeWithSelector(
                EcosystemImplMismatch.selector,
                address(bridgehubProxy),
                address(implOld),
                address(implNewer)
            )
        );
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(coreRegistry);
    }
}

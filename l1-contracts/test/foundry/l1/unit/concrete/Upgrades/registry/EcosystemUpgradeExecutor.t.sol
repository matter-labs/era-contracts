// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/objects/ICoreRegistry.sol";
import {MockProxyUpgradeInitImpl} from "contracts/dev-contracts/test/MockProxyUpgradeInitImpl.sol";
import {
    NoActiveRegistryUpgrade,
    ProxyUpgradeRowMismatch,
    RegistryCodehashMismatch
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
        ecosystemExecutor = new EcosystemUpgradeExecutor(
            ecosystemGovernor,
            makeAddr("emergencyUpgradeBoard"),
            proxyAdmin,
            coreRegistryCodehash
        );
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

    function test_applyL1Upgrade_runsFixedInitializeUpgradeAgainstTheActiveRegistry() public {
        // Bridgehub moves to an implementation that must reinitialize. The row carries only a
        // BOOLEAN — no calldata, no data: the executor invokes the fixed, argument-less
        // selector, and the implementation reads what it needs from the registry object it
        // discovers through the provider chain (msg.sender = ProxyAdmin -> owner = executor ->
        // activeRegistry()).
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
            MockProxyUpgradeInitImpl(address(bridgehubProxy)).initializedFromManifest(),
            initRegistry.manifestHash(),
            "the reinitializer must reach the registry being applied through the provider chain"
        );
    }

    function test_revertWhen_activeRegistryQueriedOutsideAnApplication() public {
        // The provider is live only WHILE rows are being applied: outside an application there
        // is no active registry for a reinitializer to read.
        vm.expectRevert(NoActiveRegistryUpgrade.selector);
        ecosystemExecutor.activeRegistry();
    }

    function test_revertWhen_executorCalledByNonEcosystemGovernance() public {
        // Not even the CTM-scope governor may drive the ecosystem executor: authority domains
        // are separate, and the entrypoint is owner-gated (no arbitrary-delegatecall surface).
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("ctmGovernor"));
        ecosystemExecutor.applyL1Upgrade(coreRegistry);
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

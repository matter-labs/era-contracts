// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/objects/ICoreRegistry.sol";
import {EcosystemImplMismatch, RegistryCodehashMismatch} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
    EcosystemContractRow,
    PinnedContract
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

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
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](2);
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
    ) internal view returns (EcosystemContractRow memory) {
        return
            EcosystemContractRow({
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: PinnedContract({addr: _implNew, codehash: _implNew.codehash})
            });
    }

    function _deployRegistry(EcosystemContractRow[] memory _rows) internal returns (ICoreRegistry) {
        return ICoreRegistry(address(new CoreRegistry(CoreRegistryManifest({contractRows: _rows}))));
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
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](1);
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

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {TestCoreRegistry} from "./TestRegistries.sol";

import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/EcosystemUpgradeExecutor.sol";
import {L1EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/ICoreRegistry.sol";
import {EcosystemImplMismatch} from "contracts/common/L1ContractErrors.sol";

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
contract EcosystemUpgradeExecutorTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal ecosystemGovernor = makeAddr("ecosystemGovernor");

    EcosystemUpgradeExecutor internal ecosystemExecutor;
    TestCoreRegistry internal coreRegistry;
    ProxyAdmin internal proxyAdmin;

    DummyImplA internal implOld;
    DummyImplB internal implNew;
    TransparentUpgradeableProxy internal bridgehubProxy;
    TransparentUpgradeableProxy internal messageRootProxy;

    uint256 internal constant NEW_VERSION = uint256(1) << 32; // 0.1.0

    function setUp() public {
        implOld = new DummyImplA();
        implNew = new DummyImplB();

        // The ecosystem executor is BOUND to (and owns) one immutable ecosystem ProxyAdmin,
        // mirroring the production ownership chain (and nothing else — no CTM authority).
        proxyAdmin = new ProxyAdmin();
        ecosystemExecutor = new EcosystemUpgradeExecutor(ecosystemGovernor, makeAddr("breakGlass"), proxyAdmin);
        proxyAdmin.transferOwnership(address(ecosystemExecutor));
        bridgehubProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");
        messageRootProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");

        coreRegistry = new TestCoreRegistry();
        // Bridgehub is a full source-checked edge (old -> new); MessageRoot pins its live
        // implementation (the executor's live comparison must skip it); L1AssetRouter pins no
        // new implementation at all (zero => skipped before any proxy interaction).
        coreRegistry.addContract(
            L1EcosystemContract.L1Bridgehub,
            address(bridgehubProxy),
            address(implOld),
            address(implNew)
        );
        coreRegistry.addContract(
            L1EcosystemContract.L1MessageRoot,
            address(messageRootProxy),
            address(implOld),
            address(implOld)
        );
        coreRegistry.addContract(L1EcosystemContract.L1AssetRouter, address(0), address(0), address(0));
    }

    function _applyL1Upgrade() internal {
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(ICoreRegistry(address(coreRegistry)));
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
        ecosystemExecutor.applyL1Upgrade(ICoreRegistry(address(coreRegistry)));
    }

    function test_revertWhen_replayingStaleRegistryWouldDowngrade() public {
        _applyL1Upgrade();

        // A LATER upgrade moves Bridgehub further (freshest impl), then the ORIGINAL registry is
        // replayed: the proxy is at neither that registry's source nor its target, so the replay
        // must revert instead of silently downgrading.
        DummyImplA implNewer = new DummyImplA();
        TestCoreRegistry laterRegistry = new TestCoreRegistry();
        laterRegistry.addContract(
            L1EcosystemContract.L1Bridgehub,
            address(bridgehubProxy),
            address(implNew),
            address(implNewer)
        );
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(ICoreRegistry(address(laterRegistry)));

        vm.expectRevert(
            abi.encodeWithSelector(
                EcosystemImplMismatch.selector,
                address(bridgehubProxy),
                address(implOld),
                address(implNewer)
            )
        );
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.applyL1Upgrade(ICoreRegistry(address(coreRegistry)));
    }
}

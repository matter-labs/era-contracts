// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {TestCoreRegistry} from "./TestRegistries.sol";

import {UpgradeExecutor} from "contracts/governance/UpgradeExecutor.sol";
import {EcosystemUpgradeModule} from "contracts/upgrades/registry/EcosystemUpgradeModule.sol";
import {L1EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/ICoreRegistry.sol";

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

/// @notice Tests the ecosystem-scoped orchestrator module. Deliberately owned by a DIFFERENT
///         governance address than the CTM-scoped executor in CTMUpgradeModule.t.sol: the two
///         authority domains are separable — each scope runs its own UpgradeExecutor with its
///         own owner, and neither module needs the other scope's registry.
contract EcosystemUpgradeModuleTest is Test {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    address internal ecosystemGovernor = makeAddr("ecosystemGovernor");

    UpgradeExecutor internal ecosystemExecutor;
    EcosystemUpgradeModule internal module;
    TestCoreRegistry internal coreRegistry;
    ProxyAdmin internal proxyAdmin;

    DummyImplA internal implOld;
    DummyImplB internal implNew;
    TransparentUpgradeableProxy internal bridgehubProxy;
    TransparentUpgradeableProxy internal messageRootProxy;

    uint256 internal constant NEW_VERSION = uint256(1) << 32; // 0.1.0

    function setUp() public {
        module = new EcosystemUpgradeModule();
        ecosystemExecutor = new UpgradeExecutor(ecosystemGovernor);

        implOld = new DummyImplA();
        implNew = new DummyImplB();

        // The ecosystem executor owns the ecosystem ProxyAdmin, mirroring the production
        // ownership chain (and nothing else — no CTM authority).
        proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(address(ecosystemExecutor));
        bridgehubProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");
        messageRootProxy = new TransparentUpgradeableProxy(address(implOld), address(proxyAdmin), hex"");

        coreRegistry = new TestCoreRegistry();
        coreRegistry.setVersions(0, NEW_VERSION);
        coreRegistry.setProxyAdmin(address(proxyAdmin));
        // Bridgehub gets a new implementation; MessageRoot pins its live implementation (the
        // module's live comparison must skip it); L1AssetRouter pins no new implementation at
        // all (zero => skipped before any proxy interaction).
        coreRegistry.addContract(L1EcosystemContract.L1Bridgehub, address(bridgehubProxy), address(implNew));
        coreRegistry.addContract(L1EcosystemContract.L1MessageRoot, address(messageRootProxy), address(implOld));
        coreRegistry.addContract(L1EcosystemContract.L1AssetRouter, address(0), address(0));
    }

    function _applyL1Upgrade() internal {
        vm.prank(ecosystemGovernor);
        ecosystemExecutor.execute(
            address(module),
            abi.encodeCall(EcosystemUpgradeModule.applyL1Upgrade, (ICoreRegistry(address(coreRegistry))))
        );
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

    function test_revertWhen_moduleCalledDirectly() public {
        // Without the ecosystem executor's identity the module has no authority over the
        // ProxyAdmin.
        vm.expectRevert("Ownable: caller is not the owner");
        module.applyL1Upgrade(ICoreRegistry(address(coreRegistry)));
    }

    function test_revertWhen_executorCalledByNonEcosystemGovernance() public {
        // Not even the CTM-scope governor may drive the ecosystem executor: authority domains
        // are separate.
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("ctmGovernor"));
        ecosystemExecutor.execute(
            address(module),
            abi.encodeCall(EcosystemUpgradeModule.applyL1Upgrade, (ICoreRegistry(address(coreRegistry))))
        );
    }
}

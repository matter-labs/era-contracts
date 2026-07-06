// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {TestCoreRegistry, TestCTMRegistry} from "./TestRegistries.sol";

import {Call} from "contracts/governance/Common.sol";
import {UpgradeExecutor} from "contracts/governance/UpgradeExecutor.sol";
import {RegistryUpgradeModule} from "contracts/upgrades/registry/RegistryUpgradeModule.sol";
import {UpgradeComposer} from "contracts/upgrades/registry/UpgradeComposer.sol";
import {CoreContract, CTMContract, EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICTMRegistry} from "contracts/upgrades/registry/ICTMRegistry.sol";
import {ICoreRegistry} from "contracts/upgrades/registry/ICoreRegistry.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {HashMismatch} from "contracts/common/L1ContractErrors.sol";

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

/// @notice Tests the orchestrator module end-to-end against a real EraChainTypeManager: the
///         UpgradeExecutor takes over CTM ownership and delegatecalls the module, which composes
///         everything from registry values.
/// @dev The registries here are storage-backed test doubles (see TestRegistries.sol) because the
///      fixture deploys at dynamic addresses; production registries are generated
///      constants-in-bytecode contracts with the identical interface.
contract RegistryUpgradeModuleTest is ChainTypeManagerTest {
    bytes32 internal constant EIP1967_IMPL_SLOT = 0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    UpgradeExecutor internal executor;
    RegistryUpgradeModule internal module;
    TestCoreRegistry internal coreRegistry;
    TestCTMRegistry internal ctmRegistry;

    uint256 internal newVersion;
    address internal chainAddress;

    function setUp() public {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        module = new RegistryUpgradeModule();
        executor = new UpgradeExecutor(governor);

        // Hand CTM ownership to the executor; the acceptOwnership leg exercises the raw-call
        // escape hatch, which is exactly how the real handover would run.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(executor));
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(chainContractAddress.acceptOwnership, ())
        });
        vm.prank(governor);
        executor.forward(calls);
        assertEq(chainContractAddress.owner(), address(executor));

        newVersion = SemVer.packSemVer(0, 1, 0);
        _setUpRegistries();
    }

    function _setUpRegistries() internal {
        coreRegistry = new TestCoreRegistry();
        ctmRegistry = new TestCTMRegistry();
        coreRegistry.setVersions(0, newVersion);
        coreRegistry.setCTMRegistry(false, address(ctmRegistry));

        ctmRegistry.setBase(false, 0, newVersion, address(chainContractAddress));
        ctmRegistry.setVerifier(newVersion, testnetVerifier);
        ctmRegistry.setCtmAddress(CTMContract.DefaultUpgrade, newVersion, makeAddr("defaultUpgrade"));
        ctmRegistry.setCtmAddress(CTMContract.DiamondInit, newVersion, makeAddr("newDiamondInit"));

        // Facet plan: AdminFacet is swapped, ExecutorFacet is added.
        bytes4[] memory adminOld = new bytes4[](2);
        adminOld[0] = bytes4(uint32(1));
        adminOld[1] = bytes4(uint32(2));
        bytes4[] memory adminNew = new bytes4[](2);
        adminNew[0] = bytes4(uint32(2));
        adminNew[1] = bytes4(uint32(3));
        bytes4[] memory executorNew = new bytes4[](1);
        executorNew[0] = bytes4(uint32(0x20));
        ctmRegistry.setCtmAddress(CTMContract.AdminFacet, 0, makeAddr("adminFacetOld"));
        ctmRegistry.setCtmAddress(CTMContract.AdminFacet, newVersion, makeAddr("adminFacetNew"));
        ctmRegistry.setCtmAddress(CTMContract.ExecutorFacet, newVersion, makeAddr("executorFacetNew"));
        ctmRegistry.addFacet(0, CTMContract.AdminFacet, adminOld);
        ctmRegistry.addFacet(newVersion, CTMContract.AdminFacet, adminNew);
        ctmRegistry.addFacet(newVersion, CTMContract.ExecutorFacet, executorNew);
        ctmRegistry.setFreezable(CTMContract.ExecutorFacet, true);

        // L2 side.
        ctmRegistry.addL2ForceDeployment(
            CoreContract.L2Bridgehub,
            IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
                deployedBytecodeInfo: hex"aa01",
                newAddress: makeAddr("l2Bridgehub")
            }),
            bytes32(uint256(1))
        );
        ctmRegistry.setL2UpgradeDelegate(makeAddr("l2UpgradeDelegate"), hex"beef");
        uint256[] memory factoryDeps = new uint256[](1);
        factoryDeps[0] = 1;
        ctmRegistry.setFactoryDepHashes(factoryDeps);
        ctmRegistry.setBaseSystemContractHashes(bytes32(uint256(0xb00)), bytes32(uint256(0xda0)), bytes32(0));
        ctmRegistry.setChainCreationData(hex"f1f2", hex"c1c2");
        ctmRegistry.setGenesis(makeAddr("genesisUpgrade"), bytes32(uint256(1)), bytes32(uint256(2)), 54);
    }

    /// @dev Recomposes the cut exactly as the module does, for hash assertions.
    function _expectedUpgradeCut(uint256 _upgradeTimestamp) internal view returns (Diamond.DiamondCutData memory) {
        ProposedUpgrade memory proposedUpgrade = UpgradeComposer.buildProposedUpgrade(
            ICTMRegistry(address(ctmRegistry)),
            _upgradeTimestamp
        );
        return
            UpgradeComposer.buildUpgradeCutData(
                ICTMRegistry(address(ctmRegistry)),
                ctmRegistry.ctmAddress(CTMContract.DefaultUpgrade, newVersion),
                abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
            );
    }

    function _applyCTMUpgrade(uint256 _deadline, uint256 _timestamp) internal {
        vm.prank(governor);
        executor.execute(
            address(module),
            abi.encodeCall(
                RegistryUpgradeModule.applyCTMUpgrade,
                (ICoreRegistry(address(coreRegistry)), false, _deadline, _timestamp)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                           applyCTMUpgrade
    //////////////////////////////////////////////////////////////*/

    function test_applyCTMUpgrade_setsVersionCutAndChainCreationParams() public {
        _applyCTMUpgrade(1000, 777);

        // Version bookkeeping.
        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 1000);
        assertEq(chainContractAddress.protocolVersionDeadline(newVersion), type(uint256).max);
        assertEq(chainContractAddress.protocolVersionVerifier(newVersion), testnetVerifier);

        // The committed upgrade cut is exactly the registry-composed one.
        bytes32 expectedCutHash = keccak256(abi.encode(_expectedUpgradeCut(777)));
        assertEq(chainContractAddress.upgradeCutHash(0), expectedCutHash);

        // Chain creation params were set from the same registry constants.
        assertEq(chainContractAddress.l1GenesisUpgrade(), makeAddr("genesisUpgrade"));
        bytes32 expectedInitialCutHash = keccak256(
            abi.encode(UpgradeComposer.buildChainCreationParams(ICTMRegistry(address(ctmRegistry))).diamondCut)
        );
        assertEq(chainContractAddress.initialCutHash(), expectedInitialCutHash);
    }

    function test_revertWhen_moduleCalledDirectly() public {
        // Without the executor's identity the module has no authority over the CTM.
        vm.expectRevert("Ownable: caller is not the owner");
        module.applyCTMUpgrade(ICoreRegistry(address(coreRegistry)), false, 1000, 777);
    }

    function test_revertWhen_executorCalledByNonGovernance() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        executor.execute(
            address(module),
            abi.encodeCall(
                RegistryUpgradeModule.applyCTMUpgrade,
                (ICoreRegistry(address(coreRegistry)), false, 1000, 777)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                             upgradeChain
    //////////////////////////////////////////////////////////////*/

    function test_upgradeChain_recomposesTheCommittedCut() public {
        _applyCTMUpgrade(1000, 777);

        // Deterministic recomposition: the cut recomposed later for per-chain execution hashes to
        // exactly what applyCTMUpgrade committed.
        assertEq(chainContractAddress.upgradeCutHash(0), keccak256(abi.encode(_expectedUpgradeCut(777))));

        // A mismatched upgradeTimestamp recomposes a different cut, and the chain's own
        // hash check rejects it. (Successful end-to-end cut execution requires the full
        // DefaultUpgrade environment — bytecode publication, tx validation — and is covered by
        // integration flows, not this unit test.)
        vm.expectRevert(
            abi.encodeWithSelector(
                HashMismatch.selector,
                keccak256(abi.encode(_expectedUpgradeCut(777))),
                keccak256(abi.encode(_expectedUpgradeCut(778)))
            )
        );
        vm.prank(governor);
        executor.execute(
            address(module),
            abi.encodeCall(
                RegistryUpgradeModule.upgradeChain,
                (ICoreRegistry(address(coreRegistry)), false, chainId, 778)
            )
        );
    }

    /*//////////////////////////////////////////////////////////////
                            applyL1Upgrade
    //////////////////////////////////////////////////////////////*/

    function test_applyL1Upgrade_upgradesChangedProxiesOnly() public {
        DummyImplA implOld = new DummyImplA();
        DummyImplB implNew = new DummyImplB();

        // The executor owns the ecosystem ProxyAdmin, mirroring the production ownership chain.
        ProxyAdmin proxyAdmin = new ProxyAdmin();
        proxyAdmin.transferOwnership(address(executor));
        TransparentUpgradeableProxy bridgehubProxy = new TransparentUpgradeableProxy(
            address(implOld),
            address(proxyAdmin),
            hex""
        );
        TransparentUpgradeableProxy messageRootProxy = new TransparentUpgradeableProxy(
            address(implOld),
            address(proxyAdmin),
            hex""
        );

        coreRegistry.setProxyAdmin(address(proxyAdmin));
        // Bridgehub gets a new implementation; MessageRoot's is unchanged and must be skipped.
        coreRegistry.addContract(
            EcosystemContract.Bridgehub,
            address(bridgehubProxy),
            address(implOld),
            address(implNew)
        );
        coreRegistry.addContract(
            EcosystemContract.MessageRoot,
            address(messageRootProxy),
            address(implOld),
            address(implOld)
        );

        vm.prank(governor);
        executor.execute(
            address(module),
            abi.encodeCall(RegistryUpgradeModule.applyL1Upgrade, (ICoreRegistry(address(coreRegistry))))
        );

        assertEq(
            address(uint160(uint256(vm.load(address(bridgehubProxy), EIP1967_IMPL_SLOT)))),
            address(implNew),
            "changed implementation must be swapped"
        );
        assertEq(
            address(uint160(uint256(vm.load(address(messageRootProxy), EIP1967_IMPL_SLOT)))),
            address(implOld),
            "unchanged implementation must be skipped"
        );
    }
}

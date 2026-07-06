// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {TestCTMRegistry} from "./TestRegistries.sol";

import {Call} from "contracts/governance/Common.sol";
import {UpgradeExecutor} from "contracts/governance/UpgradeExecutor.sol";
import {CTMUpgradeModule} from "contracts/upgrades/registry/CTMUpgradeModule.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {CoreContract, CTMContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {ICTMRegistry} from "contracts/upgrades/registry/ICTMRegistry.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {HashMismatch} from "contracts/common/L1ContractErrors.sol";

/// @notice Tests the CTM-scoped orchestrator module end-to-end against a real
///         EraChainTypeManager: a CTM-scoped UpgradeExecutor takes over CTM ownership and
///         delegatecalls the module, which composes everything from the per-CTM registry.
/// @dev CTM authority is intentionally separate from ecosystem authority — see
///      EcosystemUpgradeModule.t.sol, where a differently-owned executor drives the ecosystem
///      scope. The registry here is a storage-backed test double (see TestRegistries.sol)
///      because the fixture deploys at dynamic addresses; production registries are generated
///      constants-in-bytecode contracts with the identical interface.
contract CTMUpgradeModuleTest is ChainTypeManagerTest {
    UpgradeExecutor internal ctmExecutor;
    CTMUpgradeModule internal module;
    TestCTMRegistry internal ctmRegistry;

    uint256 internal newVersion;
    address internal chainAddress;

    function setUp() public {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        module = new CTMUpgradeModule();
        ctmExecutor = new UpgradeExecutor(governor);

        // Hand CTM ownership to the CTM-scoped executor; the acceptOwnership leg exercises the
        // raw-call escape hatch, which is exactly how the real handover would run.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(chainContractAddress.acceptOwnership, ())
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
        assertEq(chainContractAddress.owner(), address(ctmExecutor));

        newVersion = SemVer.packSemVer(0, 1, 0);
        _setUpRegistry();
    }

    function _setUpRegistry() internal {
        ctmRegistry = new TestCTMRegistry();
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
        ProposedUpgrade memory proposedUpgrade = CTMUpgradeComposer.buildProposedUpgrade(
            ICTMRegistry(address(ctmRegistry)),
            _upgradeTimestamp
        );
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                ICTMRegistry(address(ctmRegistry)),
                ctmRegistry.ctmAddress(CTMContract.DefaultUpgrade, newVersion),
                abi.encodeCall(IDefaultUpgrade.upgrade, (proposedUpgrade))
            );
    }

    function _applyCTMUpgrade(uint256 _deadline, uint256 _timestamp) internal {
        vm.prank(governor);
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(
                CTMUpgradeModule.applyCTMUpgrade,
                (ICTMRegistry(address(ctmRegistry)), _deadline, _timestamp)
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
            abi.encode(CTMUpgradeComposer.buildChainCreationParams(ICTMRegistry(address(ctmRegistry))).diamondCut)
        );
        assertEq(chainContractAddress.initialCutHash(), expectedInitialCutHash);
    }

    function test_revertWhen_moduleCalledDirectly() public {
        // Without the executor's identity the module has no authority over the CTM.
        vm.expectRevert("Ownable: caller is not the owner");
        module.applyCTMUpgrade(ICTMRegistry(address(ctmRegistry)), 1000, 777);
    }

    function test_revertWhen_executorCalledByNonGovernance() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.applyCTMUpgrade, (ICTMRegistry(address(ctmRegistry)), 1000, 777))
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
        ctmExecutor.execute(
            address(module),
            abi.encodeCall(CTMUpgradeModule.upgradeChain, (ICTMRegistry(address(ctmRegistry)), chainId, 778))
        );
    }
}

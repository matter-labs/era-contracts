// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";

import {Call} from "contracts/governance/Common.sol";
import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/CTMTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/CTMUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {ICTMTransition, L2Deployment} from "contracts/upgrades/registry/ICTMTransition.sol";
import {GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {L2EcosystemContract, CodehashPin} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {UpgradeFacetSwap} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {HashMismatch} from "contracts/common/L1ContractErrors.sol";

/// @notice Exercises the CTM-scoped orchestrator against real write-once release and transition
///         objects. Release data describes new-chain genesis; transition data describes the one
///         movement from the fixture's current version to that release.
contract CTMUpgradeExecutorTest is ChainTypeManagerTest {
    CTMUpgradeExecutor internal ctmExecutor;
    CTMRelease internal release;
    CTMTransition internal transition;

    uint256 internal newVersion;
    address internal chainAddress;

    function setUp() public {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        ctmExecutor = new CTMUpgradeExecutor(governor);

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
        release = _deployRelease();
        transition = _deployTransition(777);
    }

    function _deployRelease() internal returns (CTMRelease result) {
        result = new CTMRelease();
        result.initialize(
            CTMRelease.ReleaseManifest({
                isZKsyncOS: false,
                diamondInit: makeAddr("newDiamondInit"),
                genesisFacets: new GenesisFacet[](0),
                bootloaderHash: bytes32(uint256(0xb00)),
                defaultAccountHash: bytes32(uint256(0xda0)),
                evmEmulatorHash: bytes32(0),
                fixedForceDeploymentsData: hex"f1f2",
                genesisUpgrade: makeAddr("genesisUpgrade"),
                genesisBatchHash: bytes32(uint256(1)),
                genesisBatchCommitment: bytes32(uint256(2)),
                genesisIndexRepeatedStorageChanges: 54,
                codehashPins: new CodehashPin[](0)
            })
        );
    }

    function _deployTransition(uint256 _upgradeTimestamp) internal returns (CTMTransition result) {
        UpgradeFacetSwap[] memory facetTransitions = new UpgradeFacetSwap[](2);
        bytes4[] memory adminOld = new bytes4[](2);
        adminOld[0] = bytes4(uint32(1));
        adminOld[1] = bytes4(uint32(2));
        bytes4[] memory adminNew = new bytes4[](2);
        adminNew[0] = bytes4(uint32(2));
        adminNew[1] = bytes4(uint32(3));
        facetTransitions[0] = UpgradeFacetSwap({
            oldFacet: makeAddr("adminFacetOld"),
            newFacet: makeAddr("adminFacetNew"),
            isFreezable: false,
            oldSelectors: adminOld,
            newSelectors: adminNew
        });
        bytes4[] memory executorNew = new bytes4[](1);
        executorNew[0] = bytes4(uint32(0x20));
        facetTransitions[1] = UpgradeFacetSwap({
            oldFacet: address(0),
            newFacet: makeAddr("executorFacetNew"),
            isFreezable: true,
            oldSelectors: new bytes4[](0),
            newSelectors: executorNew
        });

        L2Deployment[] memory deployments = new L2Deployment[](1);
        deployments[0] = L2Deployment({
            key: L2EcosystemContract.L2Bridgehub,
            info: IComplexUpgrader.UniversalContractUpgradeInfo({
                upgradeType: IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
                deployedBytecodeInfo: hex"aa01",
                newAddress: makeAddr("l2Bridgehub")
            }),
            bytecodeHash: bytes32(uint256(1))
        });
        uint256[] memory factoryDeps = new uint256[](1);
        factoryDeps[0] = 1;

        result = new CTMTransition();
        result.initialize(
            CTMTransition.TransitionManifest({
                ctmProxy: address(chainContractAddress),
                oldProtocolVersion: 0,
                newProtocolVersion: newVersion,
                verifier: testnetVerifier,
                // This first transition departs from whatever release the fixture CTM was
                // genesis'd with (its current release), as the module's release-edge pin requires.
                fromRelease: chainContractAddress.currentRelease(),
                newRelease: address(release),
                defaultUpgrade: makeAddr("defaultUpgrade"),
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: _upgradeTimestamp,
                facetTransitions: facetTransitions,
                l2Deployments: deployments,
                l2UpgradeDelegateTo: makeAddr("l2UpgradeDelegate"),
                l2UpgradeDelegateCalldata: hex"beef",
                factoryDepHashes: factoryDeps,
                bootloaderHash: bytes32(uint256(0xb00)),
                defaultAccountHash: bytes32(uint256(0xda0)),
                evmEmulatorHash: bytes32(0),
                codehashPins: new CodehashPin[](0)
            })
        );
    }

    function _expectedUpgradeCut(ICTMTransition _transition) internal view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.defaultUpgrade(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }

    function _applyCTMUpgrade() internal {
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transition)));
    }

    function test_applyCTMUpgrade_setsVersionCutAndCurrentRelease() public {
        _applyCTMUpgrade();

        assertEq(chainContractAddress.protocolVersion(), newVersion);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 1000);
        assertEq(chainContractAddress.protocolVersionDeadline(newVersion), type(uint256).max);
        assertEq(chainContractAddress.protocolVersionVerifier(newVersion), testnetVerifier);
        assertEq(chainContractAddress.upgradeCutHash(0), keccak256(abi.encode(_expectedUpgradeCut(transition))));
        assertEq(chainContractAddress.currentRelease(), address(release));
        assertEq(chainContractAddress.l1GenesisUpgrade(), makeAddr("genesisUpgrade"));
    }

    function test_revertWhen_executorCalledByNonGovernance() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transition)));
    }

    function test_upgradeChain_rejectsDifferentTransition() public {
        _applyCTMUpgrade();
        CTMTransition differentTransition = _deployTransition(778);

        vm.expectRevert(
            abi.encodeWithSelector(
                HashMismatch.selector,
                keccak256(abi.encode(_expectedUpgradeCut(transition))),
                keccak256(abi.encode(_expectedUpgradeCut(differentTransition)))
            )
        );
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(differentTransition)), chainId);
    }
}

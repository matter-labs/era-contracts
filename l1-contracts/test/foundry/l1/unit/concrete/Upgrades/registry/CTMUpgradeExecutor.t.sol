// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {Utils} from "../../Utils/Utils.sol";

import {Call} from "contracts/governance/Common.sol";
import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/CTMTransition.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/CTMUpgradeExecutor.sol";
import {CTMReleaseFactory, CTMTransitionFactory} from "contracts/upgrades/registry/CTMRegistryFactory.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {ICTMTransition, L2UpgradePlan} from "contracts/upgrades/registry/ICTMTransition.sol";
import {GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    HashMismatch,
    TransitionReleaseMismatch,
    Unauthorized,
    UpgradeNotPermissionlessYet
} from "contracts/common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";

/// @notice Exercises the CTM-BOUND executor against real write-once release and transition
///         objects. Release data describes new-chain genesis; transition data describes the one
///         movement from the fixture's current version to that release — its facet/hash delta is
///         DERIVED from the release pair (a facet-neutral hop here; facet-changing hops are
///         exercised end-to-end by RegistryDrivenUpgrade.t.sol).
contract CTMUpgradeExecutorTest is ChainTypeManagerTest {
    CTMUpgradeExecutor internal ctmExecutor;
    CTMReleaseFactory internal releaseFactory;
    CTMTransitionFactory internal transitionFactory;
    CTMRelease internal fromRelease;
    CTMRelease internal release;
    CTMTransition internal transition;

    address internal breakGlass;
    uint256 internal newVersion;
    address internal chainAddress;

    function setUp() public {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        breakGlass = makeAddr("breakGlass");
        releaseFactory = new CTMReleaseFactory();
        transitionFactory = new CTMTransitionFactory();
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            breakGlass,
            IChainTypeManager(address(chainContractAddress)),
            transitionFactory
        );

        // Handover through the fixed entrypoint — no break-glass involved.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();
        assertEq(chainContractAddress.owner(), address(ctmExecutor));

        newVersion = SemVer.packSemVer(0, 1, 0);
        // Transitions require factory-attested releases on BOTH edges, so the fixture CTM's
        // mocked genesis release is replaced by a REAL factory-deployed one — through the
        // break-glass raw-call surface, which is exactly the production escape hatch for
        // out-of-band CTM state (the routine executor entrypoints cannot set currentRelease
        // directly, by design).
        fromRelease = _deployRelease(1);
        Call[] memory repoint = new Call[](1);
        repoint[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (address(fromRelease)))
        });
        vm.prank(breakGlass);
        ctmExecutor.forward(repoint);
        assertEq(chainContractAddress.currentRelease(), address(fromRelease));

        release = _deployRelease(2);
        transition = _deployTransition(777);
    }

    /// @param _commitmentNonce Differentiates otherwise-identical release manifests (the factory
    ///        is deployOrGet per manifest hash, so identical manifests resolve to ONE instance).
    function _deployRelease(uint256 _commitmentNonce) internal returns (CTMRelease result) {
        // The release describes the complete chain state after the (facet-neutral) hop this
        // suite drives: the fixture's full facet routing (explicit selectors, inline pins) and
        // the carried base-system hashes — the transition derives an EMPTY delta from it.
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({
                facet: facetCuts[i].facet,
                isFreezable: facetCuts[i].isFreezable,
                selectors: facetCuts[i].selectors,
                codehash: facetCuts[i].facet.codehash
            });
        }
        result = CTMRelease(
            releaseFactory.deployOrGetRelease(
                CTMRelease.ReleaseManifest({
                diamondInit: diamondInit,
                diamondInitCodehash: diamondInit.codehash,
                genesisFacets: genesisFacets,
                bootloaderHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                defaultAccountHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                evmEmulatorHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                fixedForceDeploymentsData: hex"f1f2",
                genesisUpgrade: makeAddr("genesisUpgrade"),
                genesisUpgradeCodehash: bytes32(0),
                genesisBatchHash: bytes32(uint256(1)),
                genesisBatchCommitment: bytes32(_commitmentNonce),
                genesisIndexRepeatedStorageChanges: 54
                })
            )
        );
    }

    function _deployTransition(uint256 _upgradeTimestamp) internal returns (CTMTransition result) {
        return _deployTransitionFrom(_upgradeTimestamp, chainContractAddress.currentRelease(), 0);
    }

    function _deployTransitionFrom(
        uint256 _upgradeTimestamp,
        address _fromRelease,
        uint256 _oldProtocolVersion
    ) internal returns (CTMTransition result) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        deployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.EraForceDeployment,
            deployedBytecodeInfo: hex"aa01",
            newAddress: makeAddr("l2Bridgehub")
        });
        uint256[] memory factoryDeps = new uint256[](1);
        factoryDeps[0] = 1;

        result = CTMTransition(
            transitionFactory.deployOrGetTransition(
                CTMTransition.TransitionManifest({
                releaseFactory: address(releaseFactory),
                oldProtocolVersion: _oldProtocolVersion,
                newProtocolVersion: newVersion,
                verifier: testnetVerifier,
                verifierCodehash: testnetVerifier.codehash,
                // The default transition departs from whatever release the fixture CTM was
                // genesis'd with (its current release), as the executor's release-edge pin requires.
                fromRelease: _fromRelease,
                newRelease: address(release),
                upgradeEngine: makeAddr("upgradeEngine"),
                upgradeEngineCodehash: bytes32(0),
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: _upgradeTimestamp,
                l2Plan: L2UpgradePlan({
                    deployments: deployments,
                    delegateTo: makeAddr("l2UpgradeDelegate"),
                    delegateCalldata: hex"beef",
                    factoryDepHashes: factoryDeps
                })
                })
            )
        );
    }

    function _expectedUpgradeCut(ICTMTransition _transition) internal view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.upgradeEngine(),
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

    function test_revertWhen_forwardCalledByOwner() public {
        // Break-glass is a SEPARATE authority: even the owner cannot forward raw calls.
        Call[] memory calls = new Call[](0);
        vm.expectRevert(abi.encodeWithSelector(Unauthorized.selector, governor));
        vm.prank(governor);
        ctmExecutor.forward(calls);
    }

    function test_forwardExecutesForBreakGlassGovernor() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, 80_000_000))
        });
        vm.prank(breakGlass);
        ctmExecutor.forward(calls);
    }

    function test_revertWhen_applyCTMUpgradeFromWrongRelease() public {
        _applyCTMUpgrade();

        // Replaying the same transition trips the release edge: the CTM already moved on to the
        // transition's target release, so `fromRelease` no longer matches.
        vm.expectRevert(
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, transition.fromRelease(), address(release))
        );
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transition)));
    }

    function test_revertWhen_applyCTMUpgradeFromWrongVersion() public {
        _applyCTMUpgrade();

        // A transition with the RIGHT release edge (departs from the now-current release, toward
        // a fresh distinct release so it is not a patch) but a STALE version edge must trip the
        // executor's independent version assert.
        address appliedRelease = address(release);
        release = _deployRelease(3);
        CTMTransition staleVersionTransition = _deployTransitionFrom(779, appliedRelease, 0);

        vm.expectRevert(abi.encodeWithSelector(OutdatedProtocolVersion.selector, newVersion, 0));
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(staleVersionTransition)));
    }

    function test_upgradeChain_rejectsDifferentTransition() public {
        _applyCTMUpgrade();
        // Same edges as the committed transition, but a different timestamp -> a different
        // composed cut -> the chain's upgradeCutHash check trips.
        CTMTransition differentTransition = _deployTransitionFrom(778, transition.fromRelease(), 0);

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

    function test_revertWhen_strangerUpgradesChainBeforeDeadline() public {
        _applyCTMUpgrade();

        // Owner-driven during the window; permissionless only once the old-version deadline
        // (1000, set by the transition) has passed. The happy permissionless path is exercised
        // in RegistryDrivenUpgrade.t.sol with a real upgrade engine.
        vm.warp(999);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotPermissionlessYet.selector, 1000));
        vm.prank(makeAddr("stranger"));
        ctmExecutor.upgradeChain(ICTMTransition(address(transition)), chainId);
    }
}

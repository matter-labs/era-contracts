// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {Utils} from "../../Utils/Utils.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {
    CTM_CONTRACT_COUNT,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    TransitionNotCommitted,
    RegistryCodehashMismatch,
    TransitionReleaseMismatch,
    Unauthorized,
    UpgradeNotPermissionlessYet
} from "contracts/common/L1ContractErrors.sol";
import {OutdatedProtocolVersion} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {
    AuthoredL2Plan,
    GenesisFacet,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest,
    PinnedContract,
    ProxyUpgradeRow
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice Exercises the CTM-BOUND executor against real write-once release and transition
///         objects. Release data describes new-chain genesis; transition data describes the one
///         movement from the fixture's current version to that release — its facet/hash delta is
///         DERIVED from the release pair (a facet-neutral hop here; facet-changing hops are
///         exercised end-to-end by RegistryDrivenUpgrade.t.sol).
contract CTMUpgradeExecutorTest is ChainTypeManagerTest {
    CTMUpgradeExecutor internal ctmExecutor;
    ProxyAdmin internal ctmProxyAdmin;
    CTMRelease internal fromRelease;
    CTMRelease internal release;
    CTMTransition internal transition;

    address internal emergencyUpgradeBoard;
    uint256 internal newVersion;
    address internal chainAddress;
    address internal genesisUpgradeAddr;
    address internal upgradeEngineAddr;

    function setUp() public {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);
        _mockMigrationPausedFromBridgehub();

        emergencyUpgradeBoard = makeAddr("emergencyUpgradeBoard");
        ctmProxyAdmin = new ProxyAdmin();
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            emergencyUpgradeBoard,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            Utils.transitionCodehash()
        );

        // Handover through the fixed entrypoint — no break-glass involved.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();
        assertEq(chainContractAddress.owner(), address(ctmExecutor));

        newVersion = SemVer.packSemVer(0, 1, 0);
        // The pinned genesisUpgrade / upgradeEngine stand-ins must carry real code — the
        // registry's codehash pin rejects codeless targets — so etch them and pin their real
        // codehash below.
        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");
        upgradeEngineAddr = makeAddr("upgradeEngine");
        vm.etch(upgradeEngineAddr, hex"600043");
        // Transitions require real releases on BOTH edges, so the fixture CTM's mocked genesis
        // release is replaced by a real one — through the break-glass raw-call surface, which is
        // exactly the production escape hatch for out-of-band CTM state (the routine executor
        // entrypoints cannot set currentRelease directly, by design).
        fromRelease = _deployRelease(1);
        Call[] memory repoint = new Call[](1);
        repoint[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (address(fromRelease)))
        });
        vm.prank(emergencyUpgradeBoard);
        ctmExecutor.forward(repoint);
        assertEq(chainContractAddress.currentRelease(), address(fromRelease));

        release = _deployRelease(2);
        transition = _deployTransition(777);
    }

    /// @param _commitmentNonce Differentiates otherwise-identical release manifests.
    /// @dev The release describes the complete chain state after the (facet-neutral) hop this
    ///      suite drives: the fixture's full facet routing (explicit selectors, inline pins) and
    ///      the carried base-system hashes — the transition derives an EMPTY delta from it.
    function _releaseManifest(uint256 _commitmentNonce) internal view returns (ReleaseManifest memory) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({
                facet: PinnedContract({addr: facetCuts[i].facet, codehash: facetCuts[i].facet.codehash}),
                isFreezable: facetCuts[i].isFreezable
            });
        }
        return
            ReleaseManifest({
                diamondInit: PinnedContract({addr: diamondInit, codehash: diamondInit.codehash}),
                verifier: PinnedContract({addr: address(testnetVerifier), codehash: address(testnetVerifier).codehash}),
                genesisUpgrade: PinnedContract({addr: genesisUpgradeAddr, codehash: genesisUpgradeAddr.codehash}),
                genesisFacets: genesisFacets,
                genesis: ReleaseGenesisData({
                    bootloaderHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    defaultAccountHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    evmEmulatorHash: Utils.TEST_BASE_SYSTEM_CONTRACT_HASH,
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(_commitmentNonce),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                // Length-checked inventory; content is irrelevant to this fixture.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
            });
    }

    function _deployRelease(uint256 _commitmentNonce) internal returns (CTMRelease result) {
        result = new CTMRelease(_releaseManifest(_commitmentNonce));
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

        ProxyUpgradeRow[] memory noProxyUpgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        result = new CTMTransition(
            TransitionManifest({
                oldProtocolVersion: _oldProtocolVersion,
                newProtocolVersion: newVersion,
                // The default transition departs from whatever release the fixture CTM was
                // genesis'd with (its current release), as the executor's release-edge pin requires.
                fromRelease: _fromRelease,
                newRelease: address(release),
                upgradeEngine: PinnedContract({addr: upgradeEngineAddr, codehash: upgradeEngineAddr.codehash}),
                proxyUpgrades: noProxyUpgrades,
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: _upgradeTimestamp,
                l2Plan: AuthoredL2Plan({
                    extraDeployments: deployments,
                    delegateTo: makeAddr("l2UpgradeDelegate"),
                    delegateCalldata: hex"beef",
                    factoryDepHashes: factoryDeps
                })
            })
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
        // The verifier is pinned by the release the CTM now points at, not by a version-keyed map.
        assertEq(CTMRelease(chainContractAddress.currentRelease()).verifier(), address(testnetVerifier));
        // The transition is the only commitment: the deprecated hash stays untouched and the cut
        // derives on read.
        assertEq(chainContractAddress.upgradeTransition(0), address(transition));
        assertEq(chainContractAddress.upgradeCutHash(0), bytes32(0));
        assertEq(
            keccak256(abi.encode(chainContractAddress.upgradeCutForVersion(0))),
            keccak256(abi.encode(_expectedUpgradeCut(transition)))
        );
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

    function test_forwardExecutesForEmergencyUpgradeBoard() public {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, 80_000_000))
        });
        vm.prank(emergencyUpgradeBoard);
        ctmExecutor.forward(calls);
    }

    /// @dev `acceptCTMOwnership` is deliberately permissionless: it can only ever COMPLETE a
    ///      transfer already initiated toward this executor — Ownable2Step's pending-owner edge
    ///      is the real gate, so a caller restriction adds nothing.
    function test_acceptCTMOwnershipPermissionlessButGatedByNomination() public {
        // Without a pending nomination, any caller just hits the Ownable2Step edge.
        vm.prank(makeAddr("stranger"));
        vm.expectRevert("Ownable2Step: caller is not the new owner");
        ctmExecutor.acceptCTMOwnership();

        // Break-glass hands the CTM back to governance, which nominates the executor again;
        // a stranger may then complete the handover — the accept only ever lands on the executor.
        Call[] memory giveBack = new Call[](1);
        giveBack[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeWithSignature("transferOwnership(address)", governor)
        });
        vm.prank(emergencyUpgradeBoard);
        ctmExecutor.forward(giveBack);
        vm.prank(governor);
        chainContractAddress.acceptOwnership();
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));

        vm.prank(makeAddr("stranger"));
        ctmExecutor.acceptCTMOwnership();
        assertEq(chainContractAddress.owner(), address(ctmExecutor), "accept must land ownership on the executor");
        assertEq(chainContractAddress.pendingOwner(), address(0), "no pending owner may survive the accept");
    }

    // The transition pins the deadline its edge was approved with (1000 in this fixture), but the
    // deadline is operational state that keeps moving after the commit — the executor's fixed
    // entrypoint must keep overriding it, repeatedly, without break-glass.
    function test_setProtocolVersionDeadline_overridesTransitionPinnedDeadline() public {
        _applyCTMUpgrade();
        assertEq(chainContractAddress.protocolVersionDeadline(0), 1000);

        vm.prank(governor);
        ctmExecutor.setProtocolVersionDeadline(0, 5000);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 5000);

        vm.prank(governor);
        ctmExecutor.setProtocolVersionDeadline(0, 8000);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 8000);
    }

    function test_revertWhen_setProtocolVersionDeadlineByStranger() public {
        _applyCTMUpgrade();
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.setProtocolVersionDeadline(0, 5000);
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

    function test_revertWhen_setCurrentReleaseIsNotTheAuditedCode() public {
        // Release provenance is the CTM's own invariant — the transition deliberately delegates it
        // upward. An object that does not run the audited `CTMRelease` code is refused when set as
        // `currentRelease`, however well-formed it otherwise looks.
        address impostor = makeAddr("notARelease");
        vm.etch(impostor, hex"600044");
        Call[] memory repoint = new Call[](1);
        repoint[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (impostor))
        });

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                impostor,
                Utils.releaseCodehash(),
                impostor.codehash
            )
        );
        vm.prank(emergencyUpgradeBoard);
        ctmExecutor.forward(repoint);
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

    /// @dev The chain needs the transition itself, not just its cut hash, to rebuild the cut.
    function test_applyCTMUpgrade_recordsTheCommittedTransition() public {
        uint256 oldVersion = chainContractAddress.protocolVersion();
        _applyCTMUpgrade();

        assertEq(
            chainContractAddress.upgradeTransition(oldVersion),
            address(transition),
            "the CTM must record the transition chains rebuild their cut from"
        );
    }

    function test_upgradeChain_rejectsDifferentTransition() public {
        _applyCTMUpgrade();
        // Same edges as the committed transition, but a different object. The chain executes the
        // cut its CTM committed, so naming a different transition must be refused rather than
        // silently running the committed one.
        CTMTransition differentTransition = _deployTransitionFrom(778, transition.fromRelease(), 0);

        vm.expectRevert(
            abi.encodeWithSelector(TransitionNotCommitted.selector, address(differentTransition), address(transition))
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

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {Utils} from "../../Utils/Utils.sol";
import {UtilsFacet} from "../../Utils/UtilsFacet.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {
    CTM_CONTRACT_COUNT,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {EcosystemUpgradeExecutor} from "contracts/upgrades/registry/executors/EcosystemUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {GovernanceUpgradeTimer} from "contracts/upgrades/GovernanceUpgradeTimer.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IDefaultUpgrade} from "contracts/upgrades/IDefaultUpgrade.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {MAX_GAS_PER_TRANSACTION} from "contracts/common/Config.sol";
import {
    L2BytecodeNotPublished,
    TransitionNotCommitted,
    RegistryCodehashMismatch,
    TransitionReleaseMismatch,
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

/// @notice The shared fixture of the CTM-bound executor suites (`CTMUpgradeExecutorTest`,
///         `CTMUpgradeLifecycleTest`): a real ZKsyncOS CTM with one chain, the two domain
///         executors (each owning its own `ProxyAdmin`), the fixture's REAL `L1ChainAssetHandler`
///         as the migration-pause holder, and real write-once release/transition objects. The
///         bootstrap-join authorizations the recurring lifecycle needs (upgrade pauser on the
///         ChainAssetHandler, CTM-executor authorization on the ecosystem executor) are wired
///         the way the v34 CTM prepare's stage 2 wires them; see {docs/upgrade-stage-lifecycle.md}.
/// @dev Every fixture transition departs from the fixture's current release toward `release`,
///      names NO ecosystem leg (`coreRegistry` zero) and pins a fresh zero-delay timer bound to
///      the executor, so stage 1 is admissible in the same block as stage 0. Suites that need a
///      CTM-domain row, an ecosystem leg or a delayed timer build the manifest through
///      `_transitionManifest` and adjust it before deploying.
abstract contract CTMUpgradeExecutorFixture is ChainTypeManagerTest {
    CTMUpgradeExecutor internal ctmExecutor;
    ProxyAdmin internal ctmProxyAdmin;
    EcosystemUpgradeExecutor internal ecosystemExecutor;
    ProxyAdmin internal ecosystemProxyAdmin;
    CTMRelease internal fromRelease;
    CTMRelease internal release;
    CTMTransition internal transition;
    /// @dev The pinned delegate-calldata composer every fixture transition carries: a test-only
    ///      stand-in returning `DELEGATE_CALLDATA` regardless of its inputs.
    FixedDelegateCalldataComposer internal delegateComposer;

    uint256 internal newVersion;
    address internal chainAddress;
    address internal genesisUpgradeAddr;
    address internal upgradeEngineAddr;

    /// @dev Dummy EVM bytecode of the L2 upgrade delegate every fixture transition carries as its
    ///      one Unsafe extra (see {L2PlanFixtures}); published on the fixture supplier in `setUp`.
    bytes internal constant L2_DELEGATE_CODE = hex"de1e";
    /// @dev The delegate calldata `delegateComposer` composes.
    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    function setUp() public virtual {
        deploy();
        chainAddress = createNewChain(getDiamondCutData(diamondInit));
        _mockGetZKChainFromBridgehub(chainAddress);

        // The two authority domains, each behind its own ProxyAdmin. The ecosystem executor is
        // bound first because the CTM executor pins it as an immutable.
        ecosystemProxyAdmin = new ProxyAdmin();
        ecosystemExecutor = new EcosystemUpgradeExecutor(governor, ecosystemProxyAdmin, Utils.coreRegistryCodehash());
        ecosystemProxyAdmin.transferOwnership(address(ecosystemExecutor));

        ctmProxyAdmin = new ProxyAdmin();
        ctmExecutor = new CTMUpgradeExecutor(
            governor,
            IChainTypeManager(address(chainContractAddress)),
            ctmProxyAdmin,
            ecosystemExecutor,
            Utils.transitionCodehash()
        );
        ctmProxyAdmin.transferOwnership(address(ctmExecutor));

        // Handover through the fixed entrypoint — no escape hatch involved.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();
        assertEq(chainContractAddress.owner(), address(ctmExecutor));

        // The one bootstrap-join authorization stage 0 requires: an authorized CTM executor on
        // the ecosystem executor. Pausing its own CTM's migrations needs no registration — the
        // ChainAssetHandler derives that from the CTM ownership the executor already holds.
        vm.prank(governor);
        ecosystemExecutor.setCTMExecutorAuthorization(address(ctmExecutor), true);

        newVersion = SemVer.packSemVer(0, 1, 0);
        // The pinned genesisUpgrade / upgradeEngine stand-ins must carry real code — the
        // registry's codehash pin rejects codeless targets — so etch them and pin their real
        // codehash below.
        genesisUpgradeAddr = makeAddr("genesisUpgrade");
        vm.etch(genesisUpgradeAddr, hex"600042");
        upgradeEngineAddr = makeAddr("upgradeEngine");
        vm.etch(upgradeEngineAddr, hex"600043");
        delegateComposer = new FixedDelegateCalldataComposer(DELEGATE_CALLDATA);
        // Transitions require real releases on BOTH edges, so the fixture CTM's mocked genesis
        // release is replaced by a real one — through the owner-gated raw-call escape hatch, which
        // is exactly the production route for out-of-band CTM state (the routine executor
        // entrypoints cannot set currentRelease directly, by design).
        fromRelease = _deployRelease(1);
        Call[] memory repoint = new Call[](1);
        repoint[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setCurrentRelease, (address(fromRelease)))
        });
        vm.prank(governor);
        ctmExecutor.forward(repoint);
        assertEq(chainContractAddress.currentRelease(), address(fromRelease));

        // The delegate's bytecode is a factory dependency of every fixture transition, and
        // stage 1 requires it published on the CTM's supplier before the edge commits.
        assertEq(chainContractAddress.L1_BYTECODES_SUPPLIER(), address(bytecodesSupplier));
        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(L2_DELEGATE_CODE));

        release = _deployRelease(2);
        transition = _deployTransition(777);
    }

    /// @param _manifestNonce Differentiates otherwise-identical release manifests (via the
    ///        genesis batch hash — the COMMITMENT must be exactly 1 for the ZKsync OS CTM).
    /// @dev The release describes the complete chain state after the (facet-neutral) hop this
    ///      suite drives: the fixture's full facet routing (explicit selectors, inline pins) —
    ///      the transition derives an EMPTY delta from it.
    function _releaseManifest(uint256 _manifestNonce) internal view returns (ReleaseManifest memory) {
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
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(_manifestNonce),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                // Length-checked inventory; content is irrelevant to this fixture.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
            });
    }

    function _deployRelease(uint256 _manifestNonce) internal returns (CTMRelease result) {
        result = new CTMRelease(_releaseManifest(_manifestNonce));
    }

    function _pin(address _addr) internal view returns (PinnedContract memory) {
        return PinnedContract({addr: _addr, codehash: _addr.codehash});
    }

    /// @dev A transition's timer: bound to the executor (`TIMER_GOVERNANCE`, the only address
    ///      that can start it), owned by governance (the bounded extension right). Zero delays
    ///      make stage 1 admissible in the block stage 0 ran in.
    function _newTimer(uint256 _initialDelay, uint256 _maxAdditionalDelay) internal returns (GovernanceUpgradeTimer) {
        return new GovernanceUpgradeTimer(_initialDelay, _maxAdditionalDelay, address(ctmExecutor), governor);
    }

    function _deployTransition(uint256 _upgradeTimestamp) internal returns (CTMTransition result) {
        return _deployTransitionFrom(_upgradeTimestamp, chainContractAddress.currentRelease(), 0);
    }

    function _deployTransitionFrom(
        uint256 _upgradeTimestamp,
        address _fromRelease,
        uint256 _oldProtocolVersion
    ) internal returns (CTMTransition result) {
        return _deployTransitionWithDelegate(_upgradeTimestamp, _fromRelease, _oldProtocolVersion, L2_DELEGATE_CODE);
    }

    function _deployTransitionWithDelegate(
        uint256 _upgradeTimestamp,
        address _fromRelease,
        uint256 _oldProtocolVersion,
        bytes memory _delegateCode
    ) internal returns (CTMTransition result) {
        result = new CTMTransition(
            _transitionManifest(_upgradeTimestamp, _fromRelease, _oldProtocolVersion, _delegateCode)
        );
    }

    /// @dev The default fixture manifest: the L2 side is the minimal well-formed plan (the
    ///      delegate, force-deployed Unsafe at its bytecode-derived address, with its bytecode as
    ///      the one factory dependency); all CTM-domain slots inert; no ecosystem leg; a fresh
    ///      zero-delay timer bound to the executor.
    function _transitionManifest(
        uint256 _upgradeTimestamp,
        address _fromRelease,
        uint256 _oldProtocolVersion,
        bytes memory _delegateCode
    ) internal returns (TransitionManifest memory) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        deployments[0] = L2PlanFixtures.unsafeDeployment(_delegateCode);
        uint256[] memory factoryDeps = L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(_delegateCode));

        return
            TransitionManifest({
                oldProtocolVersion: _oldProtocolVersion,
                newProtocolVersion: newVersion,
                // The default transition departs from whatever release the fixture CTM was
                // genesis'd with (its current release), as the executor's release-edge pin requires.
                fromRelease: _fromRelease,
                newRelease: address(release),
                upgradeEngine: _pin(upgradeEngineAddr),
                proxyUpgrades: new ProxyUpgradeRow[](CTM_CONTRACT_COUNT),
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: _upgradeTimestamp,
                l2Plan: AuthoredL2Plan({
                    extraDeployments: deployments,
                    delegateTo: deployments[0].newAddress,
                    delegateComposer: _pin(address(delegateComposer)),
                    factoryDepHashes: factoryDeps
                }),
                coreRegistry: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                upgradeTimer: _pin(address(_newTimer(0, 0)))
            });
    }

    function _expectedUpgradeCut(ICTMTransition _transition) internal view returns (Diamond.DiamondCutData memory) {
        return
            CTMUpgradeComposer.buildUpgradeCutData(
                _transition.upgradeEngine(),
                abi.encodeCall(IDefaultUpgrade.upgradeFromTransition, (address(_transition)))
            );
    }

    // ─────────────────────────── lifecycle drivers (as governance) ───────────────────────────

    function _stage0(CTMTransition _transition) internal {
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(_transition)));
    }

    function _stage1(CTMTransition _transition) internal {
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(_transition)));
    }

    function _stage2(CTMTransition _transition) internal {
        vm.prank(governor);
        ctmExecutor.stage2(ICTMTransition(address(_transition)));
    }

    /// @dev Stages 0 and 1: the transition is committed on the CTM and still mid-lifecycle.
    function _prepareAndExecute(CTMTransition _transition) internal {
        _stage0(_transition);
        _stage1(_transition);
    }

    /// @dev The whole L1 lifecycle; the slot is free again afterwards.
    function _runLifecycle(CTMTransition _transition) internal {
        _prepareAndExecute(_transition);
        _stage2(_transition);
    }

    function _assertStage(ICTMUpgradeExecutor.UpgradeStage _expected) internal view {
        assertTrue(ctmExecutor.pendingStage() == _expected, "unexpected lifecycle stage");
    }
}

/// @notice Exercises the CTM-BOUND executor against real write-once release and transition
///         objects: the stage-1 commit and what it writes, the fixed passthroughs, the post-state
///         check and the per-chain entrypoint. Release data describes new-chain genesis;
///         transition data describes the one movement from the fixture's current version to that
///         release — its facet delta is DERIVED from the release pair (a facet-neutral hop here;
///         facet-changing hops are exercised end-to-end by RegistryDrivenUpgrade.t.sol). The
///         lifecycle's own ordering, authority and pause rules are CTMUpgradeLifecycle.t.sol.
contract CTMUpgradeExecutorTest is CTMUpgradeExecutorFixture {
    function test_stage1_setsVersionCutAndCurrentRelease() public {
        _prepareAndExecute(transition);

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
            keccak256(abi.encode(_expectedUpgradeCut(ICTMTransition(address(transition)))))
        );
        assertEq(chainContractAddress.currentRelease(), address(release));
        assertEq(chainContractAddress.l1GenesisUpgrade(), makeAddr("genesisUpgrade"));
    }

    function test_revertWhen_executorCalledByNonGovernance() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.stage0(ICTMTransition(address(transition)));
    }

    function test_forwardExecutesForOwner() public {
        // The escape hatch shares the owner role with the fixed entrypoints (its mechanics are the
        // base suite's business); here it must reach the bound CTM with the executor's authority.
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, MAX_GAS_PER_TRANSACTION))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);

        assertEq(IGetters(chainAddress).getPriorityTxMaxGasLimit(), MAX_GAS_PER_TRANSACTION);
    }

    function test_revertWhen_forwardCalledByStranger() public {
        Call[] memory calls = new Call[](0);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
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

        // The owner hands the CTM back to itself through the escape hatch and nominates the
        // executor again; a stranger may then complete the handover — the accept only ever lands
        // on the executor.
        Call[] memory giveBack = new Call[](1);
        giveBack[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeWithSignature("transferOwnership(address)", governor)
        });
        vm.prank(governor);
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
    // entrypoint must keep overriding it, repeatedly, without the escape hatch.
    function test_setProtocolVersionDeadline_overridesTransitionPinnedDeadline() public {
        _prepareAndExecute(transition);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 1000);

        vm.prank(governor);
        ctmExecutor.setProtocolVersionDeadline(0, 5000);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 5000);

        vm.prank(governor);
        ctmExecutor.setProtocolVersionDeadline(0, 8000);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 8000);
    }

    function test_revertWhen_setProtocolVersionDeadlineByStranger() public {
        _prepareAndExecute(transition);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.setProtocolVersionDeadline(0, 5000);
    }

    function test_revertWhen_stage0FromWrongRelease() public {
        _runLifecycle(transition);

        // Replaying a completed transition trips the release edge: the CTM already moved on to the
        // transition's target release, so `fromRelease` no longer matches.
        vm.expectRevert(
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, transition.fromRelease(), address(release))
        );
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(transition)));
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
        vm.prank(governor);
        ctmExecutor.forward(repoint);
    }

    function test_revertWhen_stage0FromWrongVersion() public {
        _runLifecycle(transition);

        // A transition with the RIGHT release edge (departs from the now-current release, toward
        // a fresh distinct release so it is not a patch) but a STALE version edge must trip the
        // executor's independent version assert.
        address appliedRelease = address(release);
        release = _deployRelease(3);
        CTMTransition staleVersionTransition = _deployTransitionFrom(779, appliedRelease, 0);

        vm.expectRevert(abi.encodeWithSelector(OutdatedProtocolVersion.selector, newVersion, 0));
        vm.prank(governor);
        ctmExecutor.stage0(ICTMTransition(address(staleVersionTransition)));
    }

    /// @dev Publication is live L1 state, so it is checked where the edge COMMITS (stage 1): a
    ///      transition whose factory dependency is not yet on the CTM's supplier prepares fine but
    ///      cannot be executed — the whole stage reverts, the CTM is untouched and the lifecycle
    ///      stays open with the pause held — and executes once the bytecode is published, with
    ///      nothing else changed.
    function test_stage1_requiresFactoryDepsPublishedOnTheCtmSupplier() public {
        bytes memory unpublishedDelegate = hex"de1f";
        CTMTransition unpublished = _deployTransitionWithDelegate(
            777,
            chainContractAddress.currentRelease(),
            0,
            unpublishedDelegate
        );
        assertEq(bytecodesSupplier.evmPublishingBlock(keccak256(unpublishedDelegate)), 0, "fixture: not yet published");
        _stage0(unpublished);

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(unpublishedDelegate)));
        vm.prank(governor);
        ctmExecutor.stage1(ICTMTransition(address(unpublished)));
        assertEq(chainContractAddress.protocolVersion(), 0, "a refused stage 1 must not move the CTM");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "a refused stage 1 must commit nothing");
        assertEq(
            chainContractAddress.currentRelease(),
            address(fromRelease),
            "a refused stage 1 must keep the release"
        );
        assertEq(address(ctmExecutor.pendingTransition()), address(unpublished), "the lifecycle must stay open");
        _assertStage(ICTMUpgradeExecutor.UpgradeStage.Prepared);
        assertTrue(
            chainAssetHandler.migrationPausedFor(address(chainContractAddress)),
            "this CTM's migrations must stay paused"
        );

        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(unpublishedDelegate));

        _stage1(unpublished);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the same transition executes once published");
        assertEq(chainContractAddress.upgradeTransition(0), address(unpublished));
        _stage2(unpublished);
        assertEq(address(ctmExecutor.pendingTransition()), address(0), "the lifecycle must complete");
    }

    /// @dev The chain needs the transition itself, not just its cut hash, to rebuild the cut.
    function test_stage1_recordsTheCommittedTransition() public {
        uint256 oldVersion = chainContractAddress.protocolVersion();
        _prepareAndExecute(transition);

        assertEq(
            chainContractAddress.upgradeTransition(oldVersion),
            address(transition),
            "the CTM must record the transition chains rebuild their cut from"
        );
    }

    // ──────────────── routine operational and recovery passthroughs ────────────────
    // Each passthrough runs end-to-end: executor -> bound CTM -> the fixture's real chain diamond,
    // asserting the chain-side (or CTM-side) state and event. All of them share one unhappy path,
    // the executor's `onlyOwner` gate, checked before the CTM is reached.

    function test_freezeChain_freezesTheChainDiamond() public {
        assertFalse(IGetters(chainAddress).isDiamondStorageFrozen());

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.Freeze();
        vm.prank(governor);
        ctmExecutor.freezeChain(chainId);

        assertTrue(IGetters(chainAddress).isDiamondStorageFrozen(), "the freeze must land on the chain diamond");
    }

    function test_unfreezeChain_unfreezesTheChainDiamond() public {
        vm.prank(governor);
        ctmExecutor.freezeChain(chainId);
        assertTrue(IGetters(chainAddress).isDiamondStorageFrozen());

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.Unfreeze();
        vm.prank(governor);
        ctmExecutor.unfreezeChain(chainId);

        assertFalse(IGetters(chainAddress).isDiamondStorageFrozen(), "the unfreeze must land on the chain diamond");
    }

    function test_revertBatches_rollsTheChainBackToTheGivenBatch() public {
        // Committing real batches is the executor-facet suites' business; the fixture's UtilsFacet
        // seeds the committed counter so the revert has something to roll back.
        UtilsFacet(chainAddress).util_setTotalBatchesCommitted(3);
        assertEq(IGetters(chainAddress).getTotalBatchesCommitted(), 3);

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IExecutor.BlocksRevert(1, 0, 0);
        vm.prank(governor);
        ctmExecutor.revertBatches(chainId, 1);

        assertEq(IGetters(chainAddress).getTotalBatchesCommitted(), 1, "the chain must be rolled back to batch 1");
    }

    function test_setValidator_togglesTheChainValidatorFlag() public {
        address newValidator = makeAddr("newValidator");
        assertFalse(IGetters(chainAddress).isValidator(newValidator));

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.ValidatorStatusUpdate(newValidator, true);
        vm.prank(governor);
        ctmExecutor.setValidator(chainId, newValidator, true);
        assertTrue(IGetters(chainAddress).isValidator(newValidator), "the validator must be enabled on the chain");

        vm.prank(governor);
        ctmExecutor.setValidator(chainId, newValidator, false);
        assertFalse(IGetters(chainAddress).isValidator(newValidator), "the validator must be disabled again");
    }

    function test_setPriorityTxMaxGasLimit_setsTheChainCap() public {
        uint256 oldLimit = IGetters(chainAddress).getPriorityTxMaxGasLimit();
        assertTrue(oldLimit != MAX_GAS_PER_TRANSACTION, "the fixture must start below the cap for the change to show");

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.NewPriorityTxMaxGasLimit(oldLimit, MAX_GAS_PER_TRANSACTION);
        vm.prank(governor);
        ctmExecutor.setPriorityTxMaxGasLimit(chainId, MAX_GAS_PER_TRANSACTION);

        assertEq(IGetters(chainAddress).getPriorityTxMaxGasLimit(), MAX_GAS_PER_TRANSACTION);
    }

    function test_setPorterAvailability_setsTheChainFlag() public {
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);
        assertFalse(utilsFacet.util_getZkPorterAvailability());

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.IsPorterAvailableStatusUpdate(true);
        vm.prank(governor);
        ctmExecutor.setPorterAvailability(chainId, true);

        assertTrue(utilsFacet.util_getZkPorterAvailability(), "porter availability must land on the chain");
    }

    function test_deactivatePriorityMode_clearsTheChainFlag() public {
        // Entering priority mode is the chain's own flow (a permanent rollup with stale priority
        // ops), covered by the priority-mode suites; the fixture's UtilsFacet arms the flag so the
        // passthrough has something to clear.
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);
        utilsFacet.util_setPriorityModeActivated(true);

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.PriorityModeDeactivated();
        vm.prank(governor);
        ctmExecutor.deactivatePriorityMode(chainId);

        assertFalse(utilsFacet.util_getPriorityModeActivated(), "priority mode must be cleared on the chain");
    }

    function test_setValidatorTimelockPostV29_updatesTheCtm() public {
        address oldTimelock = chainContractAddress.validatorTimelockPostV29();
        address newTimelock = makeAddr("validatorTimelockPostV29");

        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewValidatorTimelockPostV29(oldTimelock, newTimelock);
        vm.prank(governor);
        ctmExecutor.setValidatorTimelockPostV29(newTimelock);

        assertEq(chainContractAddress.validatorTimelockPostV29(), newTimelock);
    }

    function test_revertWhen_passthroughsCalledByStranger() public {
        address newValidator = makeAddr("newValidator");
        address newTimelock = makeAddr("validatorTimelockPostV29");
        address oldTimelock = chainContractAddress.validatorTimelockPostV29();
        uint256 oldLimit = IGetters(chainAddress).getPriorityTxMaxGasLimit();
        UtilsFacet(chainAddress).util_setPriorityModeActivated(true);

        vm.startPrank(makeAddr("stranger"));
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.freezeChain(chainId);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.unfreezeChain(chainId);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.revertBatches(chainId, 0);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.setValidator(chainId, newValidator, true);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.setPriorityTxMaxGasLimit(chainId, MAX_GAS_PER_TRANSACTION);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.setPorterAvailability(chainId, true);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.deactivatePriorityMode(chainId);
        vm.expectRevert("Ownable: caller is not the owner");
        ctmExecutor.setValidatorTimelockPostV29(newTimelock);
        vm.stopPrank();

        // Nothing reached the chain or the CTM.
        assertFalse(IGetters(chainAddress).isDiamondStorageFrozen());
        assertFalse(IGetters(chainAddress).isValidator(newValidator));
        assertEq(IGetters(chainAddress).getPriorityTxMaxGasLimit(), oldLimit);
        assertFalse(UtilsFacet(chainAddress).util_getZkPorterAvailability());
        assertTrue(UtilsFacet(chainAddress).util_getPriorityModeActivated());
        assertEq(chainContractAddress.validatorTimelockPostV29(), oldTimelock);
    }

    // ─────────────────────────── post-state verification ───────────────────────────

    function test_validateTransitionApplied_revertsBeforeAndPassesAfterApply() public {
        // Nothing is committed for the transition's departing version yet.
        vm.expectRevert(abi.encodeWithSelector(TransitionNotCommitted.selector, address(transition), address(0)));
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(transition)));

        _prepareAndExecute(transition);

        // A view over live state — anyone may run the post-state check.
        vm.prank(makeAddr("stranger"));
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(transition)));
    }

    /// @dev `>=` semantics: the check verifies the transition LANDED, not that it is still the
    ///      newest — a later hop moving the CTM's version further must not invalidate it, as
    ///      long as the transition's CTM-domain rows (inert here) still hold.
    function test_validateTransitionApplied_survivesALaterVersionBump() public {
        _runLifecycle(transition);
        CTMTransition first = transition;
        uint256 firstVersion = newVersion;

        // Second hop: departs from the now-current release and version toward a fresh release.
        address appliedRelease = address(release);
        release = _deployRelease(4);
        newVersion = SemVer.packSemVer(0, 2, 0);
        CTMTransition second = _deployTransitionFrom(880, appliedRelease, firstVersion);
        _runLifecycle(second);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "second hop must move the CTM beyond");

        ctmExecutor.validateTransitionApplied(ICTMTransition(address(first)));
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(second)));
    }

    function test_upgradeChain_rejectsDifferentTransition() public {
        _prepareAndExecute(transition);
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
        _prepareAndExecute(transition);

        // Owner-driven during the window; permissionless only once the old-version deadline
        // (1000, set by the transition) has passed. The happy permissionless path is exercised
        // in RegistryDrivenUpgrade.t.sol with a real upgrade engine.
        vm.warp(999);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotPermissionlessYet.selector, 1000));
        vm.prank(makeAddr("stranger"));
        ctmExecutor.upgradeChain(ICTMTransition(address(transition)), chainId);
    }
}

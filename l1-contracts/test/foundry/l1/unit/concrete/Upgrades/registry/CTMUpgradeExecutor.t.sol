// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {UtilsFacet} from "../../Utils/UtilsFacet.sol";

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {Call} from "contracts/governance/Common.sol";
import {IUpgradeExecutorBase} from "contracts/governance/IUpgradeExecutorBase.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {IProxyUpgradeTransition} from "contracts/upgrades/registry/objects/IProxyUpgradeTransition.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract,
    L2_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {CTMUpgradeExecutor} from "contracts/upgrades/registry/executors/CTMUpgradeExecutor.sol";
import {ICTMUpgradeExecutor} from "contracts/upgrades/registry/executors/ICTMUpgradeExecutor.sol";
import {CoreUpgradeExecutor} from "contracts/upgrades/registry/executors/CoreUpgradeExecutor.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";

import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {IExecutor} from "contracts/state-transition/chain-interfaces/IExecutor.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {PRIORITY_TX_MAX_GAS_LIMIT} from "contracts/common/Config.sol";
import {
    L2BytecodeNotPublished,
    TransitionNotCommitted,
    TransitionReleaseMismatch,
    UpgradeNotPermissionlessYet
} from "contracts/common/L1ContractErrors.sol";
import {
    GenesisFacet,
    ProxyUpgradeDomain,
    ProxyUpgradeRow,
    ProxyUpgradeTransitionManifest,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";

/// @notice The shared fixture of the registry executor suites (`CTMUpgradeExecutorTest`,
///         `UpgradeBundleExecutionTest`, `CTMExecutorDomainsTest`): a real ZKsyncOS CTM with one
///         chain, the two domain executors (each owning its own `ProxyAdmin`) owned by `governor`
///         the way the v35 bootstrap leaves them, and real write-once release/transition objects.
///         See {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev Every fixture transition departs from the fixture's current release toward `release`.
abstract contract CTMUpgradeExecutorFixture is ChainTypeManagerTest {
    CTMUpgradeExecutor internal ctmExecutor;
    ProxyAdmin internal ctmProxyAdmin;
    CoreUpgradeExecutor internal coreExecutor;
    ProxyAdmin internal ecosystemProxyAdmin;
    CTMRelease internal fromRelease;
    CTMRelease internal release;
    CTMTransition internal transition;
    /// @dev The pinned delegate-calldata composer every fixture transition carries: a test-only
    ///      stand-in returning `DELEGATE_CALLDATA` regardless of its inputs.
    FixedDelegateCalldataComposer internal delegateComposer;

    uint256 internal newVersion;
    address internal chainAddress;
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

        // The ecosystem domain: its executor owns the ecosystem ProxyAdmin.
        ecosystemProxyAdmin = new ProxyAdmin();
        coreExecutor = new CoreUpgradeExecutor(governor, ecosystemProxyAdmin);
        ecosystemProxyAdmin.transferOwnership(address(coreExecutor));

        // The CTM domain: its executor owns the CTM and the CTM-domain ProxyAdmin.
        ctmProxyAdmin = new ProxyAdmin();
        ctmExecutor = new CTMUpgradeExecutor(governor, IChainTypeManager(address(chainContractAddress)), ctmProxyAdmin);
        ctmProxyAdmin.transferOwnership(address(ctmExecutor));

        // Handover through the fixed entrypoint — no escape hatch involved.
        vm.prank(governor);
        chainContractAddress.transferOwnership(address(ctmExecutor));
        vm.prank(governor);
        ctmExecutor.acceptCTMOwnership();
        assertEq(chainContractAddress.owner(), address(ctmExecutor));

        newVersion = SemVer.packSemVer(0, 1, 0);
        // The pinned upgradeEngine stand-in must carry real code — a transition's `validate()`
        // rejects codeless members — so etch it.
        upgradeEngineAddr = makeAddr("upgradeEngine");
        vm.etch(upgradeEngineAddr, hex"600043");
        delegateComposer = new FixedDelegateCalldataComposer(DELEGATE_CALLDATA);
        // Transitions depart from the CTM's release, so the fixture CTM was initialized on a real
        // one ({_fixtureGenesisRelease}) rather than the suite's mocked stand-in.
        assertEq(chainContractAddress.currentRelease(), address(fromRelease));

        // The delegate's bytecode is a factory dependency of every fixture transition, and
        // `applyCTMUpgrade` requires it published on the CTM's supplier before the edge commits.
        assertEq(chainContractAddress.L1_BYTECODES_SUPPLIER(), address(bytecodesSupplier));
        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(L2_DELEGATE_CODE));

        release = _deployRelease(2, newVersion);
        transition = _deployTransition(777);
    }

    /// @inheritdoc ChainTypeManagerTest
    /// @dev The departing release every fixture transition names, at the fixture CTM's version 0.
    ///      Installing it validates that every facet self-describes, which the fixture's test facets
    ///      only do once mocked.
    function _fixtureGenesisRelease() internal override returns (address) {
        _mockFacetSelfDescriptions(facetCuts);
        fromRelease = _deployRelease(1, 0);
        return address(fromRelease);
    }

    /// @param _manifestNonce Differentiates otherwise-identical release manifests (via the
    ///        genesis batch hash — the COMMITMENT must be exactly 1 for the ZKsync OS CTM).
    /// @param _protocolVersion The version the release IS.
    /// @dev The release describes the complete chain state after the (facet-neutral) hop this
    ///      suite drives: the fixture's full facet routing (explicit selectors, inline pins) —
    ///      the transition derives an EMPTY delta from it. Its genesis upgrade is the fixture's real
    ///      one, since the fixture chain is created from the first release.
    function _releaseManifest(
        uint256 _manifestNonce,
        uint256 _protocolVersion
    ) internal view returns (ReleaseManifest memory) {
        GenesisFacet[] memory genesisFacets = new GenesisFacet[](facetCuts.length);
        for (uint256 i = 0; i < facetCuts.length; ++i) {
            genesisFacets[i] = GenesisFacet({facet: facetCuts[i].facet, isFreezable: facetCuts[i].isFreezable});
        }
        return
            ReleaseManifest({
                protocolVersion: _protocolVersion,
                diamondInit: diamondInit,
                verifier: address(testnetVerifier),
                genesisUpgrade: address(genesisUpgradeContract),
                genesisFacets: genesisFacets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: L2PlanFixtures.emptyTableForceDeploymentsData(),
                    genesisBatchHash: bytes32(_manifestNonce),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                // Length-checked inventory; content is irrelevant to this fixture.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                l2SystemProxyBytecodeInfo: ""
            });
    }

    function _deployRelease(uint256 _manifestNonce, uint256 _protocolVersion) internal returns (CTMRelease result) {
        result = new CTMRelease(_releaseManifest(_manifestNonce, _protocolVersion));
    }

    function _deployTransition(uint256 _upgradeTimestamp) internal returns (CTMTransition result) {
        return _deployTransitionFrom(_upgradeTimestamp, chainContractAddress.currentRelease());
    }

    /// @dev Toward the fixture's current `release`; the version edge is the two releases' own.
    function _deployTransitionFrom(uint256 _upgradeTimestamp, address _fromRelease) internal returns (CTMTransition) {
        return _deployTransitionWithDelegate(_upgradeTimestamp, _fromRelease, L2_DELEGATE_CODE);
    }

    function _deployTransitionWithDelegate(
        uint256 _upgradeTimestamp,
        address _fromRelease,
        bytes memory _delegateCode
    ) internal returns (CTMTransition result) {
        result = new CTMTransition(_transitionManifest(_upgradeTimestamp, _fromRelease, _delegateCode));
    }

    /// @dev The default fixture manifest: the L2 side is the minimal plan (the delegate's bytecode
    ///      info — the object constructs its Unsafe deployment and pins its bytecode as the one
    ///      factory dependency). Infrastructure rows ride a `ProxyUpgradeTransition`, never the
    ///      transition.
    function _transitionManifest(
        uint256 _upgradeTimestamp,
        address _fromRelease,
        bytes memory _delegateCode
    ) internal view returns (TransitionManifest memory) {
        return
            TransitionManifest({
                // The default transition departs from whatever release the fixture CTM was
                // genesis'd with (its current release), as the executor's release-edge pin requires.
                fromRelease: _fromRelease,
                newRelease: address(release),
                upgradeEngine: upgradeEngineAddr,
                oldProtocolVersionDeadline: 1000,
                upgradeTimestamp: _upgradeTimestamp,
                l2Plan: L2PlanFixtures.delegatePlan(_delegateCode, address(delegateComposer))
            });
    }

    function _expectedUpgradeCut(ICTMTransition _transition) internal view returns (Diamond.DiamondCutData memory) {
        return CTMUpgradeComposer.buildUpgradeCutData(_transition);
    }

    /// @dev A row departing from `_expectedOldImpl` toward `_implNew` on `_proxy`, without a
    ///      reinitializer.
    function _row(
        address _proxy,
        address _expectedOldImpl,
        address _implNew
    ) internal pure returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: _expectedOldImpl,
                implNew: _implNew,
                callInitializeUpgrade: false
            });
    }

    /// @dev A Core-domain transition carrying `_inventoryRow` in the `L1Bridgehub` slot (the slot is a label —
    ///      the row's own proxy address is its identity).
    function _deployCoreTransition(ProxyUpgradeRow memory _inventoryRow) internal returns (ProxyUpgradeTransition) {
        ProxyUpgradeRow[] memory inventory = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        inventory[uint256(L1EcosystemContract.L1Bridgehub)] = _inventoryRow;
        return
            new ProxyUpgradeTransition(
                ProxyUpgradeTransitionManifest({domain: ProxyUpgradeDomain.Core, proxyUpgrades: inventory})
            );
    }

    /// @dev A CTM-domain transition carrying `_inventoryRow` in the `ValidatorTimelock` slot.
    function _deployCTMInfrastructureTransition(
        ProxyUpgradeRow memory _inventoryRow
    ) internal returns (ProxyUpgradeTransition) {
        ProxyUpgradeRow[] memory inventory = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        inventory[uint256(CTMContract.ValidatorTimelock)] = _inventoryRow;
        return
            new ProxyUpgradeTransition(
                ProxyUpgradeTransitionManifest({domain: ProxyUpgradeDomain.CTM, proxyUpgrades: inventory})
            );
    }

    // ─────────────────────────── drivers (as governance) ───────────────────────────

    /// @dev Governance commits `_transition` through the CTM executor.
    function _execute(CTMTransition _transition) internal {
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(_transition)));
    }
}

/// @notice Exercises the CTM-BOUND executor against real write-once release and transition
///         objects: the commit `applyCTMUpgrade` makes and what it writes, CTM owner calls through
///         `forward`, the post-state check and the per-chain entrypoint. Release data describes
///         new-chain genesis; transition data describes the one movement from the fixture's current
///         version to that release — its facet delta is DERIVED from the release pair (a
///         facet-neutral hop here; facet-changing hops are exercised end-to-end by
///         RegistryDrivenUpgrade.t.sol). Multi-leg governance bundles are UpgradeBundleExecution.t.sol.
contract CTMUpgradeExecutorTest is CTMUpgradeExecutorFixture {
    /// @dev A limit within the 2^24 admission cap that differs from the one a fresh chain starts with.
    uint256 internal constant NEW_PRIORITY_TX_MAX_GAS_LIMIT = PRIORITY_TX_MAX_GAS_LIMIT / 2;

    function test_applyCTMUpgrade_setsVersionCutAndCurrentRelease() public {
        uint256 oldVersion = chainContractAddress.protocolVersion();
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit ICTMUpgradeExecutor.CTMUpgradeApplied(address(transition), oldVersion, newVersion);
        _execute(transition);

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
        assertEq(chainContractAddress.l1GenesisUpgrade(), address(genesisUpgradeContract));
    }

    function test_revertWhen_applyCTMUpgradeCalledByNonGovernance() public {
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transition)));
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "nothing may be committed");
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM must not move");
    }

    function test_revertWhen_applyInfrastructureUpgradeCalledByNonGovernance() public {
        IProxyUpgradeTransition infrastructure = IProxyUpgradeTransition(
            address(_deployCTMInfrastructureTransition(_row(makeAddr("proxy"), makeAddr("old"), makeAddr("new"))))
        );
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.applyInfrastructureUpgrade(infrastructure);
    }

    function test_forwardExecutesForOwner() public {
        // The escape hatch shares the owner role with the fixed entrypoints (its mechanics are the
        // base suite's business); here it must reach the bound CTM with the executor's authority.
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, NEW_PRIORITY_TX_MAX_GAS_LIMIT))
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);

        assertEq(IGetters(chainAddress).getPriorityTxMaxGasLimit(), NEW_PRIORITY_TX_MAX_GAS_LIMIT);
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
    // deadline is operational state that keeps moving after the commit — governance keeps
    // overriding it, repeatedly, through the executor's `forward`.
    function test_setProtocolVersionDeadline_throughForward_overridesTransitionPinnedDeadline() public {
        _execute(transition);
        assertEq(chainContractAddress.protocolVersionDeadline(0), 1000);

        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.UpdateProtocolVersionDeadline(0, 5000);
        _forwardToCTM(abi.encodeCall(IChainTypeManager.setProtocolVersionDeadline, (0, 5000)));
        assertEq(chainContractAddress.protocolVersionDeadline(0), 5000);

        _forwardToCTM(abi.encodeCall(IChainTypeManager.setProtocolVersionDeadline, (0, 8000)));
        assertEq(chainContractAddress.protocolVersionDeadline(0), 8000);
    }

    function test_revertWhen_applyCTMUpgradeReplaysAnAppliedTransition() public {
        _execute(transition);

        // Replaying an applied transition trips the release edge: the CTM already moved on to the
        // transition's target release, so `fromRelease` no longer matches.
        vm.expectRevert(
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, transition.fromRelease(), address(release))
        );
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(transition)));
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the applied edge stands");
    }

    /// @dev A transition departing from the CTM's release cannot carry a stale version edge: the
    ///      edge is read off the releases, and the CTM's release and version only move together.
    ///      The executor's version assert is therefore redundant with its release assert for any
    ///      genuine object, and stays as the second of two independent checks.
    function test_aTransitionFromTheLiveReleaseDepartsFromTheLiveVersion() public {
        _execute(transition);

        address appliedRelease = address(release);
        uint256 appliedVersion = newVersion;
        newVersion = SemVer.packSemVer(0, 2, 0);
        release = _deployRelease(3, newVersion);
        CTMTransition next = _deployTransitionFrom(779, appliedRelease);

        assertEq(next.oldProtocolVersion(), appliedVersion, "the edge departs from the applied release's version");
        assertEq(chainContractAddress.protocolVersion(), appliedVersion, "which is the CTM's live version");
        _execute(next);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "and executes from there");
    }

    /// @dev Publication is live L1 state, so it is checked where the edge COMMITS: a transition
    ///      whose factory dependency is not yet on the CTM's supplier deploys fine but cannot be
    ///      executed — the whole call reverts and the CTM is untouched — and executes once the
    ///      bytecode is published, with nothing else changed.
    function test_applyCTMUpgrade_requiresFactoryDepsPublishedOnTheCtmSupplier() public {
        bytes memory unpublishedDelegate = hex"de1f";
        CTMTransition unpublished = _deployTransitionWithDelegate(
            777,
            chainContractAddress.currentRelease(),
            unpublishedDelegate
        );
        assertEq(bytecodesSupplier.evmPublishingBlock(keccak256(unpublishedDelegate)), 0, "fixture: not yet published");

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(unpublishedDelegate)));
        vm.prank(governor);
        ctmExecutor.applyCTMUpgrade(ICTMTransition(address(unpublished)));
        assertEq(chainContractAddress.protocolVersion(), 0, "a refused execution must not move the CTM");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "a refused execution must commit nothing");
        assertEq(
            chainContractAddress.currentRelease(),
            address(fromRelease),
            "a refused execution must keep the release"
        );

        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(unpublishedDelegate));

        _execute(unpublished);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "the same transition executes once published");
        assertEq(chainContractAddress.upgradeTransition(0), address(unpublished));
    }

    /// @dev The chain needs the transition itself, not just its cut hash, to rebuild the cut.
    function test_applyCTMUpgrade_recordsTheCommittedTransition() public {
        uint256 oldVersion = chainContractAddress.protocolVersion();
        _execute(transition);

        assertEq(
            chainContractAddress.upgradeTransition(oldVersion),
            address(transition),
            "the CTM must record the transition chains rebuild their cut from"
        );
    }

    // ──────────────── routine operational and recovery calls through `forward` ────────────────
    // The executor has no typed passthroughs: every CTM owner operation outside its fixed
    // entrypoints goes through the owner-gated, event-logged `forward`. Each runs end-to-end —
    // executor -> bound CTM -> the fixture's real chain diamond — asserting the chain-side (or
    // CTM-side) state and event.

    function test_forwardFreezeChain_freezesTheChainDiamond() public {
        assertFalse(IGetters(chainAddress).isDiamondStorageFrozen());

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.Freeze();
        _forwardToCTM(abi.encodeCall(IChainTypeManager.freezeChain, (chainId)));

        assertTrue(IGetters(chainAddress).isDiamondStorageFrozen(), "the freeze must land on the chain diamond");
    }

    function test_forwardUnfreezeChain_unfreezesTheChainDiamond() public {
        _forwardToCTM(abi.encodeCall(IChainTypeManager.freezeChain, (chainId)));
        assertTrue(IGetters(chainAddress).isDiamondStorageFrozen());

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.Unfreeze();
        _forwardToCTM(abi.encodeCall(IChainTypeManager.unfreezeChain, (chainId)));

        assertFalse(IGetters(chainAddress).isDiamondStorageFrozen(), "the unfreeze must land on the chain diamond");
    }

    function test_forwardRevertBatches_rollsTheChainBackToTheGivenBatch() public {
        // Committing real batches is the executor-facet suites' business; the fixture's UtilsFacet
        // seeds the committed counter so the revert has something to roll back.
        UtilsFacet(chainAddress).util_setTotalBatchesCommitted(3);
        assertEq(IGetters(chainAddress).getTotalBatchesCommitted(), 3);

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IExecutor.BlocksRevert(1, 0, 0);
        _forwardToCTM(abi.encodeCall(IChainTypeManager.revertBatches, (chainId, 1)));

        assertEq(IGetters(chainAddress).getTotalBatchesCommitted(), 1, "the chain must be rolled back to batch 1");
    }

    function test_forwardSetValidator_togglesTheChainValidatorFlag() public {
        address newValidator = makeAddr("newValidator");
        assertFalse(IGetters(chainAddress).isValidator(newValidator));

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.ValidatorStatusUpdate(newValidator, true);
        _forwardToCTM(abi.encodeCall(IChainTypeManager.setValidator, (chainId, newValidator, true)));
        assertTrue(IGetters(chainAddress).isValidator(newValidator), "the validator must be enabled on the chain");

        _forwardToCTM(abi.encodeCall(IChainTypeManager.setValidator, (chainId, newValidator, false)));
        assertFalse(IGetters(chainAddress).isValidator(newValidator), "the validator must be disabled again");
    }

    function test_forwardSetPriorityTxMaxGasLimit_setsTheChainCap() public {
        uint256 oldLimit = IGetters(chainAddress).getPriorityTxMaxGasLimit();
        assertTrue(
            oldLimit != NEW_PRIORITY_TX_MAX_GAS_LIMIT,
            "the fixture must start at another limit for the change to show"
        );

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.NewPriorityTxMaxGasLimit(oldLimit, NEW_PRIORITY_TX_MAX_GAS_LIMIT);
        _forwardToCTM(
            abi.encodeCall(IChainTypeManager.setPriorityTxMaxGasLimit, (chainId, NEW_PRIORITY_TX_MAX_GAS_LIMIT))
        );

        assertEq(IGetters(chainAddress).getPriorityTxMaxGasLimit(), NEW_PRIORITY_TX_MAX_GAS_LIMIT);
    }

    function test_forwardDeactivatePriorityMode_clearsTheChainFlag() public {
        // Entering priority mode is the chain's own flow (a permanent rollup with stale priority
        // ops), covered by the priority-mode suites; the fixture's UtilsFacet arms the flag so the
        // call has something to clear.
        UtilsFacet utilsFacet = UtilsFacet(chainAddress);
        utilsFacet.util_setPriorityModeActivated(true);

        vm.expectEmit(true, true, true, true, chainAddress);
        emit IAdmin.PriorityModeDeactivated();
        _forwardToCTM(abi.encodeCall(IChainTypeManager.deactivatePriorityMode, (chainId)));

        assertFalse(utilsFacet.util_getPriorityModeActivated(), "priority mode must be cleared on the chain");
    }

    function test_forwardSetValidatorTimelockPostV29_updatesTheCtm() public {
        address oldTimelock = chainContractAddress.validatorTimelockPostV29();
        address newTimelock = makeAddr("validatorTimelockPostV29");

        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewValidatorTimelockPostV29(oldTimelock, newTimelock);
        _forwardToCTM(abi.encodeCall(IChainTypeManager.setValidatorTimelockPostV29, (newTimelock)));

        assertEq(chainContractAddress.validatorTimelockPostV29(), newTimelock);
    }

    /// @dev Governance no longer owns the CTM, so the only route to these owner operations is
    ///      the executor's `forward` (whose own gate is `test_revertWhen_forwardCalledByStranger`).
    function test_revertWhen_ctmOwnerOperationsCalledDirectlyByGovernance() public {
        address newValidator = makeAddr("newValidator");
        address newTimelock = makeAddr("validatorTimelockPostV29");
        address oldTimelock = chainContractAddress.validatorTimelockPostV29();
        uint256 oldLimit = IGetters(chainAddress).getPriorityTxMaxGasLimit();
        UtilsFacet(chainAddress).util_setPriorityModeActivated(true);

        vm.startPrank(governor);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.freezeChain(chainId);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.unfreezeChain(chainId);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.revertBatches(chainId, 0);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setValidator(chainId, newValidator, true);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setPriorityTxMaxGasLimit(chainId, NEW_PRIORITY_TX_MAX_GAS_LIMIT);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.deactivatePriorityMode(chainId);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setValidatorTimelockPostV29(newTimelock);
        vm.expectRevert("Ownable: caller is not the owner");
        chainContractAddress.setProtocolVersionDeadline(0, 5000);
        vm.stopPrank();

        // Nothing reached the chain or the CTM.
        assertFalse(IGetters(chainAddress).isDiamondStorageFrozen());
        assertFalse(IGetters(chainAddress).isValidator(newValidator));
        assertEq(IGetters(chainAddress).getPriorityTxMaxGasLimit(), oldLimit);
        assertTrue(UtilsFacet(chainAddress).util_getPriorityModeActivated());
        assertEq(chainContractAddress.validatorTimelockPostV29(), oldTimelock);
    }

    /// @dev Governance's one call into the bound CTM, through the executor's `forward`, asserting
    ///      the forward is logged.
    /// @param _data The CTM calldata.
    function _forwardToCTM(bytes memory _data) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({target: address(chainContractAddress), value: 0, data: _data});
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit IUpgradeExecutorBase.CallForwarded(address(chainContractAddress), 0, _data);
        vm.prank(governor);
        ctmExecutor.forward(calls);
    }

    // ─────────────────────────── post-state verification ───────────────────────────

    function test_validateTransitionApplied_revertsBeforeAndPassesAfterApply() public {
        // Nothing is committed for the transition's departing version yet.
        vm.expectRevert(abi.encodeWithSelector(TransitionNotCommitted.selector, address(transition), address(0)));
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(transition)));

        _execute(transition);

        // A view over live state — anyone may run the post-state check.
        vm.prank(makeAddr("stranger"));
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(transition)));
    }

    /// @dev `>=` semantics: the check verifies the transition LANDED, not that it is still the
    ///      newest — a later hop moving the CTM's version further must not invalidate it.
    function test_validateTransitionApplied_survivesALaterVersionBump() public {
        _execute(transition);
        CTMTransition first = transition;
        uint256 firstVersion = newVersion;

        // Second hop: departs from the now-current release and version toward a fresh release.
        address appliedRelease = address(release);
        newVersion = SemVer.packSemVer(0, 2, 0);
        release = _deployRelease(4, newVersion);
        CTMTransition second = _deployTransitionFrom(880, appliedRelease);
        assertEq(second.oldProtocolVersion(), firstVersion, "the second hop departs from the first's version");
        _execute(second);
        assertEq(chainContractAddress.protocolVersion(), newVersion, "second hop must move the CTM beyond");

        ctmExecutor.validateTransitionApplied(ICTMTransition(address(first)));
        ctmExecutor.validateTransitionApplied(ICTMTransition(address(second)));
    }

    function test_upgradeChain_rejectsDifferentTransition() public {
        _execute(transition);
        // Same edges as the committed transition, but a different object. The chain executes the
        // cut its CTM committed, so naming a different transition must be refused rather than
        // silently running the committed one.
        CTMTransition differentTransition = _deployTransitionFrom(778, transition.fromRelease());

        vm.expectRevert(
            abi.encodeWithSelector(TransitionNotCommitted.selector, address(differentTransition), address(transition))
        );
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(differentTransition)), chainId);
    }

    function test_revertWhen_strangerUpgradesChainBeforeDeadline() public {
        _execute(transition);

        // Owner-driven during the window; permissionless only once the old-version deadline
        // (1000, set by the transition) has passed. The happy permissionless path is exercised
        // in RegistryDrivenUpgrade.t.sol with a real upgrade engine.
        vm.warp(999);
        vm.expectRevert(abi.encodeWithSelector(UpgradeNotPermissionlessYet.selector, 1000));
        vm.prank(makeAddr("stranger"));
        ctmExecutor.upgradeChain(ICTMTransition(address(transition)), chainId);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ChainTypeManagerTest} from "../../state-transition/ChainTypeManager/_ChainTypeManager_Shared.t.sol";
import {RegistryDrivenUpgradeTestBase} from "./RegistryDrivenUpgrade.t.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {UtilsFacet} from "foundry-test/l1/unit/concrete/Utils/UtilsFacet.sol";

import {Call} from "contracts/governance/Common.sol";
import {IUpgradeExecutorBase} from "contracts/governance/IUpgradeExecutorBase.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {AcceptingVerifier} from "contracts/dev-contracts/test/AcceptingVerifier.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IGetters} from "contracts/state-transition/chain-interfaces/IGetters.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {
    L2BytecodeNotPublished,
    NoCommittedUpgradeCutForVersion,
    ProtocolIdMismatch,
    RegistryTargetHasNoCode,
    TransitionNotCommitted,
    TransitionReleaseMismatch
} from "contracts/common/L1ContractErrors.sol";
import {
    LegacyCutForRegistryDrivenVersion,
    TransitionDeadlineMismatch,
    UpgradeTransitionUnchanged
} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {ProtocolVersionTooSmall} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {AuthoredL2Plan, TransitionManifest} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @notice `ChainTypeManager.replaceUpgradeTransition`: governance repairs the transition committed
///         for an already-departed version, through the CTM executor's `forward`, against the real
///         chain and engines of the registry-driven fixture. See "Replacing a committed transition"
///         in {protocol-docs/ecosystem-upgrade-coordination.md}.
/// @dev The fixture's releases: R0 (the genesis release, version 0), R32 (verifier change) and R33
///      (a new AdminFacet and an L2 table row). Its transitions: `transitionV32` R0 -> R32 (L1-only)
///      and `transitionV33` R32 -> R33.
contract TransitionReplacementTest is ChainTypeManagerTest, RegistryDrivenUpgradeTestBase {
    /// @dev A delegate bytecode nobody published.
    bytes internal constant UNPUBLISHED_DELEGATE_CODE = hex"c0de99";
    /// @dev The pinned deadline every fixture transition carries.
    uint256 internal constant FIXTURE_DEADLINE = 1000;

    // ─────────────────────────────── VM hooks ───────────────────────────────

    function _deployFixture() internal override {
        deploy();
    }

    function _fixtureGenesisRelease()
        internal
        override(ChainTypeManagerTest, RegistryDrivenUpgradeTestBase)
        returns (address)
    {
        return RegistryDrivenUpgradeTestBase._fixtureGenesisRelease();
    }

    function _isZKsyncOSVariant() internal pure override returns (bool) {
        return true;
    }

    function _expectedL2UpgradeTxType() internal pure override returns (uint256) {
        return ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE;
    }

    function _l2DeploymentType() internal pure override returns (IComplexUpgrader.ContractUpgradeType) {
        return IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade;
    }

    function _registryGenesisBatchCommitment() internal pure override returns (bytes32) {
        return bytes32(uint256(1));
    }

    // ─────────────────────────────── fixtures ───────────────────────────────

    function _r0() internal view returns (address) {
        return transitionV32.fromRelease();
    }

    function _r32() internal view returns (address) {
        return transitionV32.newRelease();
    }

    function _r33() internal view returns (address) {
        return transitionV33.newRelease();
    }

    function _transition(
        address _fromRelease,
        address _newRelease,
        address _engine,
        uint256 _deadline,
        AuthoredL2Plan memory _plan
    ) internal returns (CTMTransition) {
        return
            new CTMTransition(
                TransitionManifest({
                    fromRelease: _fromRelease,
                    newRelease: _newRelease,
                    upgradeEngine: _engine,
                    oldProtocolVersionDeadline: _deadline,
                    upgradeTimestamp: 0,
                    l2Plan: _plan
                })
            );
    }

    function _delegatePlan() internal view returns (AuthoredL2Plan memory) {
        return L2PlanFixtures.delegatePlan(L2_DELEGATE_CODE, address(delegateComposer));
    }

    /// @dev A release object at `_protocolVersion` that no fixture transition names.
    function _strayRelease(uint256 _protocolVersion) internal returns (address) {
        return
            address(new CTMRelease(_releaseManifest(address(0), address(new AcceptingVerifier()), _protocolVersion)));
    }

    /// @dev A hop committed and completed on L1; the chain stays where it is.
    function _commitAndComplete(CTMTransition _transitionToCommit) internal {
        _commitHop(_transitionToCommit);
        EcosystemUpgradeOperation operation = _operationFor(_transitionToCommit);
        vm.prank(governor);
        coordinator.stage2(operation);
    }

    function _replaceCall(
        CTMTransition _expected,
        CTMTransition _replacement
    ) internal view returns (Call[] memory calls) {
        calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.replaceUpgradeTransition,
                (ICTMTransition(address(_expected)), ICTMTransition(address(_replacement)))
            )
        });
    }

    /// @dev Governance's call: the CTM's owner is the executor, so it goes through `forward`.
    function _replace(CTMTransition _expected, CTMTransition _replacement) internal {
        vm.prank(governor);
        ctmExecutor.forward(_replaceCall(_expected, _replacement));
    }

    /// @dev A refused replacement leaves the departure's commitment as it was.
    function _expectReplaceRevert(
        CTMTransition _expected,
        CTMTransition _replacement,
        uint256 _departure,
        bytes memory _error
    ) internal {
        address committedBefore = chainContractAddress.upgradeTransition(_departure);
        Call[] memory calls = _replaceCall(_expected, _replacement);
        vm.expectRevert(_error);
        vm.prank(governor);
        ctmExecutor.forward(calls);
        assertEq(chainContractAddress.upgradeTransition(_departure), committedBefore, "nothing may be replaced");
    }

    function _upgradeChain(CTMTransition _transitionToRun) internal {
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(_transitionToRun)), chainId);
    }

    function _composedL2TxHash(CTMTransition _transitionToRun) internal view returns (bytes32) {
        return
            keccak256(
                abi.encode(
                    CTMUpgradeComposer.buildL2UpgradeTx(
                        ICTMTransition(address(_transitionToRun)),
                        address(bridgehub),
                        chainId
                    )
                )
            );
    }

    // ─────────────────────────────── happy paths ───────────────────────────────

    /// @dev A -> B is replaced by A -> B' (same source and target release, now with an L2 side)
    ///      after the CTM moved on to v33. A lagging chain then executes the replacement and
    ///      continues on the untouched onward edge.
    function test_replaceBelowTheCurrentVersion_aLaggingChainExecutesTheReplacement() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        CTMTransition repaired = _transition(_r0(), _r32(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        Diamond.DiamondCutData memory repairedCut = CTMUpgradeComposer.buildUpgradeCutData(
            ICTMTransition(address(repaired))
        );

        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.UpgradeTransitionReplaced(0, address(transitionV32), address(repaired));
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewUpgradeTransition(0, address(repaired));
        vm.expectEmit(true, true, true, true, address(chainContractAddress));
        emit IChainTypeManager.NewUpgradeCutData(V32, repairedCut);
        vm.expectEmit(true, true, true, true, address(ctmExecutor));
        emit IUpgradeExecutorBase.CallForwarded(
            address(chainContractAddress),
            0,
            _replaceCall(transitionV32, repaired)[0].data
        );
        _replace(transitionV32, repaired);

        assertEq(chainContractAddress.upgradeTransition(0), address(repaired), "the departure is recommitted");
        assertEq(chainContractAddress.upgradeTransition(V32), address(transitionV33), "the onward edge is untouched");
        assertEq(chainContractAddress.protocolVersion(), V33, "the CTM version does not move");
        assertEq(chainContractAddress.currentRelease(), _r33(), "nor does its release");
        assertEq(chainContractAddress.protocolVersionDeadline(0), FIXTURE_DEADLINE, "nor the effective deadline");
        assertEq(
            keccak256(abi.encode(chainContractAddress.upgradeCutForVersion(0))),
            keccak256(abi.encode(repairedCut)),
            "chains departing version 0 now read the replacement's cut"
        );

        // The replaced object no longer upgrades anything.
        vm.expectRevert(
            abi.encodeWithSelector(TransitionNotCommitted.selector, address(transitionV32), address(repaired))
        );
        _upgradeChain(transitionV32);

        _upgradeChain(repaired);
        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "the chain lands on the replacement's target");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV32);
        assertEq(
            IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(),
            _composedL2TxHash(repaired),
            "the chain commits the replacement's L2 transaction"
        );

        // Finalizing that L2 upgrade is the server's business; the UtilsFacet stands in for it.
        UtilsFacet(chainAddress).util_setL2SystemContractsUpgradeTxHash(bytes32(0));
        _upgradeChain(transitionV33);
        assertEq(IGetters(chainAddress).getProtocolVersion(), V33, "and continues on the onward edge");
        assertEq(IGetters(chainAddress).facetAddress(IAdmin.acceptAdmin.selector), newAdminFacet);
    }

    /// @dev A -> B is replaced by A -> C, C being the CTM's current release: a lagging chain skips
    ///      the intermediate release.
    function test_replaceWithTheCurrentRelease_aLaggingChainSkipsToIt() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        CTMTransition bypass = _transition(_r0(), _r33(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        assertEq(bypass.newProtocolVersion(), V33);

        _replace(transitionV32, bypass);
        assertEq(chainContractAddress.upgradeTransition(0), address(bypass));

        _upgradeChain(bypass);
        assertEq(IGetters(chainAddress).getProtocolVersion(), V33, "the chain skips v32");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV33);
        assertEq(IGetters(chainAddress).facetAddress(IAdmin.acceptAdmin.selector), newAdminFacet);
        assertEq(IGetters(chainAddress).getL2SystemContractsUpgradeTxHash(), _composedL2TxHash(bypass));
    }

    /// @dev A chain that already crossed the replaced edge keeps the state it reached: it cannot
    ///      replay the replacement from the earlier source, and continues on its own onward edge.
    function test_aChainThatAlreadyCrossedKeepsItsStateAndContinuesOnward() public {
        _runHop(transitionV32);
        _commitAndComplete(transitionV33);
        CTMTransition bypass = _transition(_r0(), _r33(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());

        _replace(transitionV32, bypass);

        assertEq(IGetters(chainAddress).getProtocolVersion(), V32, "the replacement changes nothing installed");
        assertEq(address(IGetters(chainAddress).getVerifier()), verifierV32);
        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, V32, 0));
        _upgradeChain(bypass);

        _upgradeChain(transitionV33);
        assertEq(IGetters(chainAddress).getProtocolVersion(), V33);
    }

    /// @dev A replacement can itself be replaced (compare-and-replace against the live one).
    function test_aReplacementCanBeReplacedAgain() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        CTMTransition repaired = _transition(_r0(), _r32(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        CTMTransition bypass = _transition(_r0(), _r33(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());

        _replace(transitionV32, repaired);
        _replace(repaired, bypass);
        assertEq(chainContractAddress.upgradeTransition(0), address(bypass));
    }

    // ─────────────────────────────── refusals ───────────────────────────────

    function test_revertWhen_calledByAnyoneButTheOwner() public {
        _commitAndComplete(transitionV32);
        CTMTransition repaired = _transition(_r0(), _r32(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());

        // Governance no longer owns the CTM: its route is the executor's `forward`.
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(governor);
        chainContractAddress.replaceUpgradeTransition(
            ICTMTransition(address(transitionV32)),
            ICTMTransition(address(repaired))
        );
        Call[] memory calls = _replaceCall(transitionV32, repaired);
        vm.expectRevert("Ownable: caller is not the owner");
        vm.prank(makeAddr("stranger"));
        ctmExecutor.forward(calls);
        assertEq(chainContractAddress.upgradeTransition(0), address(transitionV32));
    }

    function test_revertWhen_theExpectedTransitionIsNotDeployed() public {
        _commitAndComplete(transitionV32);
        CTMTransition repaired = _transition(_r0(), _r32(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        address codeless = makeAddr("codelessTransition");
        _expectReplaceRevert(
            CTMTransition(codeless),
            repaired,
            0,
            abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless)
        );
    }

    function test_revertWhen_theReplacementIsNotDeployed() public {
        _commitAndComplete(transitionV32);
        address codeless = makeAddr("codelessTransition");
        _expectReplaceRevert(
            transitionV32,
            CTMTransition(codeless),
            0,
            abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless)
        );
    }

    /// @dev Compare-and-replace: a proposal naming a transition that is no longer the committed
    ///      one (here: one replaced since) is stale and refused.
    function test_revertWhen_theExpectedTransitionIsNoLongerCommitted() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        CTMTransition repaired = _transition(_r0(), _r32(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        CTMTransition bypass = _transition(_r0(), _r33(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        _replace(transitionV32, repaired);

        _expectReplaceRevert(
            transitionV32,
            bypass,
            0,
            abi.encodeWithSelector(TransitionNotCommitted.selector, address(transitionV32), address(repaired))
        );
    }

    /// @dev Only a departed version can be repaired: nothing is committed for v32 yet.
    function test_revertWhen_nothingIsCommittedForTheDeparture() public {
        _commitAndComplete(transitionV32);
        CTMTransition alternative = _transition(_r32(), _r33(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());

        _expectReplaceRevert(
            transitionV33,
            alternative,
            V32,
            abi.encodeWithSelector(TransitionNotCommitted.selector, address(transitionV33), address(0))
        );
    }

    function test_revertWhen_theReplacementIsTheCommittedTransition() public {
        _commitAndComplete(transitionV32);
        _expectReplaceRevert(
            transitionV32,
            transitionV32,
            0,
            abi.encodeWithSelector(UpgradeTransitionUnchanged.selector, address(transitionV32))
        );
    }

    /// @dev The replacement's own check surface runs: an engine whose code is gone is refused.
    function test_revertWhen_theReplacementDoesNotValidate() public {
        _commitAndComplete(transitionV32);
        address engine = address(new DefaultUpgrade());
        CTMTransition broken = _transition(_r0(), _r32(), engine, FIXTURE_DEADLINE, _delegatePlan());
        vm.etch(engine, "");

        _expectReplaceRevert(
            transitionV32,
            broken,
            0,
            abi.encodeWithSelector(RegistryTargetHasNoCode.selector, engine)
        );
    }

    function test_revertWhen_theReplacementDepartsFromAnotherRelease() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        _expectReplaceRevert(
            transitionV32,
            transitionV33,
            0,
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, _r0(), _r32())
        );
    }

    /// @dev A deadline change is a separate `setProtocolVersionDeadline`, never a side effect of a
    ///      replacement.
    function test_revertWhen_theReplacementPinsAnotherDeadline() public {
        _commitAndComplete(transitionV32);
        CTMTransition laterDeadline = _transition(
            _r0(),
            _r32(),
            defaultUpgrade,
            FIXTURE_DEADLINE + 1000,
            _delegatePlan()
        );
        _expectReplaceRevert(
            transitionV32,
            laterDeadline,
            0,
            abi.encodeWithSelector(TransitionDeadlineMismatch.selector, FIXTURE_DEADLINE, FIXTURE_DEADLINE + 1000)
        );
    }

    function test_revertWhen_theReplacementLandsBeforeTheReplacedTarget() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        CTMTransition bypass = _transition(_r0(), _r33(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        CTMTransition repaired = _transition(_r0(), _r32(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());
        _replace(transitionV32, bypass);

        _expectReplaceRevert(bypass, repaired, 0, abi.encodeWithSelector(ProtocolVersionTooSmall.selector, V33, V32));
    }

    /// @dev Nothing departs a version the CTM has not reached, so such a target has no onward
    ///      commitment.
    function test_revertWhen_theReplacementTargetsAVersionTheCtmHasNotReached() public {
        _commitAndComplete(transitionV32);
        CTMTransition ahead = _transition(_r0(), _r33(), defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());

        _expectReplaceRevert(
            transitionV32,
            ahead,
            0,
            abi.encodeWithSelector(NoCommittedUpgradeCutForVersion.selector, V33)
        );
    }

    /// @dev At the current version the target must BE the current release; another release object
    ///      of the same version number is not a destination.
    function test_revertWhen_theReplacementTargetsAnotherReleaseAtTheCurrentVersion() public {
        _commitAndComplete(transitionV32);
        address stray = _strayRelease(V32);
        CTMTransition strayed = _transition(_r0(), stray, defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());

        _expectReplaceRevert(
            transitionV32,
            strayed,
            0,
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, _r32(), stray)
        );
    }

    /// @dev Below the current version the target must be the source of the edge committed onward
    ///      from its version, or a chain landing there could not continue.
    function test_revertWhen_theReplacementTargetIsDisconnectedFromTheOnwardEdge() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        address stray = _strayRelease(V32);
        CTMTransition strayed = _transition(_r0(), stray, defaultUpgrade, FIXTURE_DEADLINE, _delegatePlan());

        _expectReplaceRevert(
            transitionV32,
            strayed,
            0,
            abi.encodeWithSelector(TransitionReleaseMismatch.selector, _r32(), stray)
        );
    }

    /// @dev A version between committed ones that nothing departs from is not a destination either.
    function test_revertWhen_theReplacementTargetsAVersionNothingDepartsFrom() public {
        _commitAndComplete(transitionV32);
        _commitAndComplete(transitionV33);
        uint256 between = V32 + 1;
        CTMTransition strayed = _transition(
            _r0(),
            _strayRelease(between),
            defaultUpgrade,
            FIXTURE_DEADLINE,
            _delegatePlan()
        );

        _expectReplaceRevert(
            transitionV32,
            strayed,
            0,
            abi.encodeWithSelector(NoCommittedUpgradeCutForVersion.selector, between)
        );
    }

    function test_revertWhen_theReplacementBytecodesAreNotPublished() public {
        _commitAndComplete(transitionV32);
        CTMTransition unpublished = _transition(
            _r0(),
            _r32(),
            defaultUpgrade,
            FIXTURE_DEADLINE,
            L2PlanFixtures.delegatePlan(UNPUBLISHED_DELEGATE_CODE, address(delegateComposer))
        );

        _expectReplaceRevert(
            transitionV32,
            unpublished,
            0,
            abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(UNPUBLISHED_DELEGATE_CODE))
        );
    }

    // ─────────────────────────────── the legacy cut setter ───────────────────────────────

    /// @dev A registry-committed departure is repaired by replacement, never by a legacy cut.
    function test_revertWhen_aRegistryCommittedDepartureIsGivenALegacyCut() public {
        _commitAndComplete(transitionV32);
        Diamond.DiamondCutData memory cut = CTMUpgradeComposer.buildUpgradeCutData(
            ICTMTransition(address(transitionV32))
        );
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(IChainTypeManager.setUpgradeDiamondCut, (cut, 0))
        });

        vm.expectRevert(abi.encodeWithSelector(LegacyCutForRegistryDrivenVersion.selector, 0));
        vm.prank(governor);
        ctmExecutor.forward(calls);
        assertEq(chainContractAddress.upgradeCutHash(0), bytes32(0), "no legacy cut hash is written");
    }
}

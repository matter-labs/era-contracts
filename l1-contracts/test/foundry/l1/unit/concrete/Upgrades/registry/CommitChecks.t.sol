// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {UtilsFacet} from "../../Utils/UtilsFacet.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {Call} from "contracts/governance/Common.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {IAdmin} from "contracts/state-transition/chain-interfaces/IAdmin.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    L2BytecodeNotPublished,
    NoCommittedUpgradeCutForVersion,
    ProtocolIdMismatch,
    RegistryEmptySelectors,
    RegistryTargetHasNoCode,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {ProtocolVersionTooSmall} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {GenesisFacet, ReleaseManifest, TransitionManifest} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @notice Every check a commit needs from the state at execution lives in the CTM
///         (`setNewVersionUpgradeFromTransition`), not in the executor wrapping it: a commit sent
///         through the executor's `forward` is held to the same ones (report §5.1). Plus the rules
///         that keep a committed version every chain can cross.
contract CommitChecksTest is CTMUpgradeExecutorFixture {
    function _commitThroughForward(CTMTransition _transition) internal {
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.setNewVersionUpgradeFromTransition,
                (ICTMTransition(address(_transition)))
            )
        });
        vm.prank(governor);
        ctmExecutor.forward(calls);
    }

    function _assertNothingCommitted() internal view {
        assertEq(chainContractAddress.protocolVersion(), 0, "the CTM version must not move");
        assertEq(chainContractAddress.upgradeTransition(0), address(0), "nothing must be committed");
        assertEq(chainContractAddress.currentRelease(), address(fromRelease), "the release must not move");
    }

    function test_revertWhen_aCommitThroughForwardDependsOnAnUnpublishedBytecode() public {
        bytes memory unpublishedDelegate = hex"de1f";
        CTMTransition unpublished = _deployTransitionWithDelegate(
            777,
            chainContractAddress.currentRelease(),
            unpublishedDelegate
        );
        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotPublished.selector, keccak256(unpublishedDelegate)));
        _commitThroughForward(unpublished);
        _assertNothingCommitted();

        L2PlanFixtures.publish(bytecodesSupplier, L2PlanFixtures.codes(unpublishedDelegate));
        _commitThroughForward(unpublished);
        assertEq(chainContractAddress.upgradeTransition(0), address(unpublished), "commits once published");
    }

    function test_revertWhen_aCommitThroughForwardNamesACodelessEngine() public {
        vm.etch(upgradeEngineAddr, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, upgradeEngineAddr));
        _commitThroughForward(transition);
        _assertNothingCommitted();
    }

    function test_revertWhen_aCommitThroughForwardNamesACodelessComposer() public {
        vm.etch(address(delegateComposer), "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, address(delegateComposer)));
        _commitThroughForward(transition);
        _assertNothingCommitted();
    }

    /// @dev The release a commit installs is validated by `_setCurrentRelease` in the same call, and
    ///      nothing moves when it does not validate. A genuine transition validates both releases at
    ///      construction, so it cannot name such a release: the transition's `newRelease()` is mocked
    ///      to isolate the install-time check from the constructor's.
    function test_revertWhen_committingTowardAReleaseThatDoesNotValidate() public {
        ReleaseManifest memory codelessMember = _releaseManifest(5, newVersion);
        address codeless = makeAddr("codelessGenesisUpgrade");
        codelessMember.genesisUpgrade = codeless;
        CTMRelease invalid = new CTMRelease(codelessMember);
        CTMTransition toward = _deployTransition(777);
        vm.mockCall(address(toward), abi.encodeCall(ICTMTransition.newRelease, ()), abi.encode(address(invalid)));
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        _execute(toward);
        _assertNothingCommitted();

        ReleaseManifest memory selectorless = _releaseManifest(6, newVersion);
        GenesisFacet[] memory facets = new GenesisFacet[](selectorless.genesisFacets.length + 1);
        for (uint256 i = 0; i < selectorless.genesisFacets.length; ++i) {
            facets[i] = selectorless.genesisFacets[i];
        }
        address emptyFacet = address(new MockSelfDescribingFacet(new bytes4[](0)));
        facets[facets.length - 1] = GenesisFacet({facet: emptyFacet, isFreezable: false});
        selectorless.genesisFacets = facets;
        invalid = new CTMRelease(selectorless);
        vm.mockCall(address(toward), abi.encodeCall(ICTMTransition.newRelease, ()), abi.encode(address(invalid)));
        vm.expectRevert(abi.encodeWithSelector(RegistryEmptySelectors.selector, emptyFacet));
        _execute(toward);
        _assertNothingCommitted();
    }

    /// @dev A transition refuses a zero engine at construction. An engine that has no code by the
    ///      commit is refused there, and nothing moves.
    function test_revertWhen_aTransitionNamesAZeroOrCodelessEngine() public {
        TransitionManifest memory manifest = _transitionManifest(
            777,
            chainContractAddress.currentRelease(),
            L2_DELEGATE_CODE
        );
        manifest.upgradeEngine = address(0);
        vm.expectRevert(ZeroAddress.selector);
        new CTMTransition(manifest);

        vm.etch(upgradeEngineAddr, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, upgradeEngineAddr));
        _execute(transition);
        _assertNothingCommitted();
    }

    /// @dev A non-increasing edge: no transition can pin one (`VersionEdgeLib`, which therefore also
    ///      covers every replacement), and the legacy cut-taking commit refuses one in
    ///      `_commitVersionEdge` (objlib-28).
    function test_revertWhen_anEdgeDoesNotMoveTheVersionForward() public {
        TransitionManifest memory manifest = _transitionManifest(
            777,
            chainContractAddress.currentRelease(),
            L2_DELEGATE_CODE
        );
        manifest.newRelease = address(fromRelease);
        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector, 0, 0));
        new CTMTransition(manifest);

        CTMRelease sameVersion = _deployRelease(3, 0);
        Call[] memory calls = new Call[](1);
        calls[0] = Call({
            target: address(chainContractAddress),
            value: 0,
            data: abi.encodeCall(
                IChainTypeManager.setNewVersionUpgrade,
                (getDiamondCutData(diamondInit), 0, type(uint256).max, address(sameVersion))
            )
        });
        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector, 0, 0));
        vm.prank(governor);
        ctmExecutor.forward(calls);
        _assertNothingCommitted();
    }

    /// @dev A chain crosses only an edge departing its own version, and no committed edge departs a
    ///      non-zero major (`VersionEdgeLib`), so the committed-cut path cannot reach the engines'
    ///      own major checks (`BaseZkSyncUpgrade._setNewProtocolVersion`, tested there).
    function test_aChainAtANonZeroMajorCannotReachACommittedCut() public {
        _execute(transition);
        uint256 nonZeroMajor = SemVer.packSemVer(1, 0, 0);
        UtilsFacet(chainAddress).util_setProtocolVersion(nonZeroMajor);

        vm.expectRevert(abi.encodeWithSelector(ProtocolIdMismatch.selector, nonZeroMajor, 0));
        vm.prank(governor);
        ctmExecutor.upgradeChain(ICTMTransition(address(transition)), chainId);

        // Nothing departs the chain's own version, so there is no cut for it to read either.
        address chainAdmin = IChainTypeManager(address(chainContractAddress)).getChainAdmin(chainId);
        vm.expectRevert(abi.encodeWithSelector(NoCommittedUpgradeCutForVersion.selector, nonZeroMajor));
        vm.prank(chainAdmin);
        IAdmin(chainAddress).upgradeChainFromVersion(chainAddress, nonZeroMajor);
        assertEq(UtilsFacet(chainAddress).util_getProtocolVersion(), nonZeroMajor, "the chain did not move");
    }
}

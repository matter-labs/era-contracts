// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {
    ITransparentUpgradeableProxy,
    TransparentUpgradeableProxy
} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ProxyUpgradeTransition} from "contracts/upgrades/registry/objects/ProxyUpgradeTransition.sol";
import {RegistryTargetHasNoCode} from "contracts/common/L1ContractErrors.sol";
import {ProxyUpgradeRow, ReleaseManifest, TransitionManifest} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @dev The check surface of the write-once objects that keep one: a release and a transition.
interface IValidatable {
    function validate() external view;
}

/// @dev Two distinct implementations so a proxy row is a real `expectedOldImpl -> implNew` edge.
contract ValidateTargetOld {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract ValidateTargetNew {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice Where "the named contract is deployed code" is enforced, member by member — the MANIFEST
///         is the spec, not the objects' code. A release's `validate()` covers its own members; a
///         transition's covers only the code it names itself (engine, composer); a proxy upgrade
///         transition's rows are code-checked when applied, all of them before the first swap
///         (`ProxyUpgradeRowLib.applyRows`). See
///         {protocol-docs/ecosystem-upgrade.md#where-each-check-lives}.
/// @dev The transition under test has a delegate and therefore names its delegate composer, so
///      the full list is exercised.
contract CodePresenceSurfacesTest is CTMUpgradeExecutorFixture {
    /// @dev `diamondInit`, `genesisUpgrade`, `verifier` — the release members that are not facets.
    uint256 internal constant RELEASE_FIXED_MEMBERS = 3;

    address internal implOld;
    address internal implNew;
    TransparentUpgradeableProxy internal ecosystemProxy;
    TransparentUpgradeableProxy internal ctmDomainProxy;
    ProxyUpgradeTransition internal coreTransition;
    ProxyUpgradeTransition internal infrastructure;
    CTMTransition internal fullTransition;

    function setUp() public override {
        super.setUp();
        implOld = address(new ValidateTargetOld());
        implNew = address(new ValidateTargetNew());

        ecosystemProxy = new TransparentUpgradeableProxy(implOld, address(ecosystemProxyAdmin), hex"");
        coreTransition = _deployCoreTransition(_row(address(ecosystemProxy)));

        fullTransition = _deployTransition(777);
        ctmDomainProxy = new TransparentUpgradeableProxy(implOld, address(ctmProxyAdmin), hex"");
        infrastructure = _deployCTMInfrastructureTransition(_row(address(ctmDomainProxy)));
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_freshObjectsValidate() public view {
        IValidatable(address(release)).validate();
        IValidatable(address(fullTransition)).validate();
    }

    /// @dev The composer is zero exactly on an L1-only edge (no delegate), and such a transition
    ///      still validates, so the code check is not silently turned into "every slot must be
    ///      filled". The target release differs from the departing one in its version only, as an
    ///      edge without an L2 side requires.
    function test_l1OnlyTransitionWithoutComposerValidates() public {
        TransitionManifest memory manifest = _transitionManifest(
            778,
            chainContractAddress.currentRelease(),
            L2_DELEGATE_CODE
        );
        manifest.newRelease = address(_deployRelease(1, newVersion));
        manifest.l2Plan = L2PlanFixtures.emptyPlan();
        CTMTransition l1Only = new CTMTransition(manifest);
        assertEq(l1Only.l2Plan().delegateComposer, address(0), "an L1-only plan names no composer");
        assertEq(l1Only.l2Plan().delegateTo, address(0), "an L1-only plan has no delegate");
        l1Only.validate();
    }

    // ─────────────────────────────── every named member ───────────────────────────────

    function test_everyReleaseMemberIsRequiredToHaveCode() public {
        address[] memory members = _releaseMembers(release.getManifest());
        assertEq(
            members.length,
            RELEASE_FIXED_MEMBERS + facetCuts.length,
            "the fixture release names its full facet set"
        );
        for (uint256 i = 0; i < members.length; ++i) {
            _assertCodelessMemberIsRefused(
                IValidatable(address(release)),
                members[i],
                abi.encodeWithSelector(RegistryTargetHasNoCode.selector, members[i])
            );
        }
    }

    /// @dev A transition names the engine and the composer; each must be code.
    function test_everyTransitionMemberIsRequiredToHaveCode() public {
        TransitionManifest memory m = fullTransition.getManifest();
        assertTrue(m.l2Plan.delegateComposer != address(0), "the fixture transition names a composer");
        address[2] memory members = [m.upgradeEngine, m.l2Plan.delegateComposer];
        for (uint256 i = 0; i < members.length; ++i) {
            _assertCodelessMemberIsRefused(
                IValidatable(address(fullTransition)),
                members[i],
                abi.encodeWithSelector(RegistryTargetHasNoCode.selector, members[i])
            );
        }
    }

    /// @dev The releases are validated at the transition's construction and where they are
    ///      installed, not again by the transition's own `validate()`: a transition still validates
    ///      with a codeless member in either release.
    function test_aTransitionDoesNotRecheckItsReleases() public {
        address releaseMember = release.getManifest().genesisUpgrade;
        vm.etch(releaseMember, "");
        fullTransition.validate();
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, releaseMember));
        release.validate();
    }

    /// @dev A row whose implementation has no code is refused, with its own diagnostic, when an
    ///      executor of either domain applies it, before any proxy moves.
    function test_aRowWithACodelessImplementationIsRefusedWhenApplied() public {
        assertEq(coreTransition.rows()[0].implNew, implNew);
        assertEq(infrastructure.rows()[0].implNew, implNew);
        vm.etch(implNew, "");

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, implNew));
        coreExecutor.applyL1Upgrade(coreTransition);
        assertEq(
            ecosystemProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ecosystemProxy))),
            implOld,
            "the core row did not land"
        );

        vm.prank(governor);
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, implNew));
        ctmExecutor.applyInfrastructureUpgrade(infrastructure);
        assertEq(
            ctmProxyAdmin.getProxyImplementation(ITransparentUpgradeableProxy(address(ctmDomainProxy))),
            implOld,
            "the CTM row did not land"
        );
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _row(address _proxy) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({proxy: _proxy, expectedOldImpl: implOld, implNew: implNew, callInitializeUpgrade: false});
    }

    /// @dev What a release names, read off its manifest: DiamondInit, genesis upgrade, verifier,
    ///      every genesis facet.
    function _releaseMembers(ReleaseManifest memory _m) internal pure returns (address[] memory members) {
        members = new address[](RELEASE_FIXED_MEMBERS + _m.genesisFacets.length);
        members[0] = _m.diamondInit;
        members[1] = _m.genesisUpgrade;
        members[2] = _m.verifier;
        for (uint256 i = 0; i < _m.genesisFacets.length; ++i) {
            members[RELEASE_FIXED_MEMBERS + i] = _m.genesisFacets[i].facet;
        }
    }

    /// @dev Empties `_member`'s code and checks `validate()` refuses it with `_error`, then restores
    ///      the state and checks the object validates again.
    function _assertCodelessMemberIsRefused(IValidatable _object, address _member, bytes memory _error) internal {
        assertTrue(_member.code.length != 0, "the fixture member must have code before it is emptied");

        uint256 snapshot = vm.snapshotState();
        vm.etch(_member, "");
        vm.expectRevert(_error);
        _object.validate();
        assertTrue(vm.revertToState(snapshot), "restore the emptied member");

        _object.validate();
    }
}

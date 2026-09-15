// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {TransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CTMUpgradeExecutorFixture} from "./CTMUpgradeExecutor.t.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {
    CTMContract,
    L1EcosystemContract,
    L1_ECOSYSTEM_CONTRACT_COUNT
} from "contracts/upgrades/registry/libraries/ContractIdentifiers.sol";
import {RegistryTargetHasNoCode} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
    ProxyUpgradeRow,
    ReleaseManifest,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @dev The check surface every write-once registry object exposes, so one helper can drive a
///      release, a transition and a core registry alike.
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

/// @notice `validate()` is the enforcement surface every write-once registry object exposes: it
///         refuses a manifest naming a member that is not deployed code (see "Validation" in
///         {docs/registry-driven-upgrades.md}). These tests enumerate every contract a release, a
///         transition and a core registry name — the MANIFEST is the spec, not the objects' code —
///         and check that emptying any ONE of them is refused with that member's own diagnostic,
///         so no named member can be left unchecked.
/// @dev The transition under test names every optional member (a delegate composer, a
///      participating CTM-domain row) so the full list is exercised.
contract CodePresenceSurfacesTest is CTMUpgradeExecutorFixture {
    /// @dev `diamondInit`, `genesisUpgrade`, `verifier` — the release members that are not facets.
    uint256 internal constant RELEASE_FIXED_MEMBERS = 3;
    /// @dev `upgradeEngine`, `upgradeTimer` — the transition members every manifest carries.
    uint256 internal constant TRANSITION_FIXED_MEMBERS = 2;

    address internal implOld;
    address internal implNew;
    CoreRegistry internal coreRegistry;
    /// @dev The fixture's default transition plus one CTM-domain row.
    CTMTransition internal fullTransition;

    function setUp() public override {
        super.setUp();
        implOld = address(new ValidateTargetOld());
        implNew = address(new ValidateTargetNew());

        ProxyUpgradeRow[] memory ecosystemInventory = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        TransparentUpgradeableProxy ecosystemProxy = new TransparentUpgradeableProxy(
            implOld,
            address(ecosystemProxyAdmin),
            hex""
        );
        ecosystemInventory[uint256(L1EcosystemContract.L1Bridgehub)] = _row(address(ecosystemProxy));
        coreRegistry = new CoreRegistry(CoreRegistryManifest({proxyUpgrades: ecosystemInventory}));

        TransitionManifest memory manifest = _transitionManifest(
            777,
            chainContractAddress.currentRelease(),
            0,
            L2_DELEGATE_CODE
        );
        TransparentUpgradeableProxy ctmDomainProxy = new TransparentUpgradeableProxy(
            implOld,
            address(ctmProxyAdmin),
            hex""
        );
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(address(ctmDomainProxy));
        fullTransition = new CTMTransition(manifest);
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_freshObjectsValidate() public view {
        IValidatable(address(release)).validate();
        IValidatable(address(fullTransition)).validate();
        IValidatable(address(coreRegistry)).validate();
    }

    /// @dev The optional-zero member stays legal: a transition with no composer still validates,
    ///      so the code check is not silently turned into "every slot must be filled".
    function test_transitionWithoutComposerValidates() public {
        TransitionManifest memory manifest = _transitionManifest(
            778,
            chainContractAddress.currentRelease(),
            0,
            L2_DELEGATE_CODE
        );
        manifest.l2Plan.delegateComposer = address(0);
        CTMTransition uncomposed = new CTMTransition(manifest);
        uncomposed.validate();
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
            _assertCodelessMemberIsRefused(IValidatable(address(release)), members[i]);
        }
    }

    /// @dev A transition's list is its own members plus BOTH release edges' lists: an emptied
    ///      member of either release must surface through the transition too.
    function test_everyTransitionMemberIsRequiredToHaveCode() public {
        address[] memory members = _transitionMembers(fullTransition.getManifest());
        for (uint256 i = 0; i < members.length; ++i) {
            _assertCodelessMemberIsRefused(IValidatable(address(fullTransition)), members[i]);
        }
    }

    function test_everyCoreRegistryRowIsRequiredToHaveCode() public {
        ProxyUpgradeRow[] memory rows = coreRegistry.ecosystemRows();
        assertEq(rows.length, 1, "one participating row");
        for (uint256 i = 0; i < rows.length; ++i) {
            _assertCodelessMemberIsRefused(IValidatable(address(coreRegistry)), rows[i].implNew);
        }
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _row(address _proxy) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: implOld,
                implNew: implNew,
                callInitializeUpgrade: false,
                admin: ProxyAdmin(address(0))
            });
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

    /// @dev What a transition names, read off its manifest: engine, timer, composer, every
    ///      participating row's implementation, and both release edges' own lists.
    function _transitionMembers(TransitionManifest memory _m) internal view returns (address[] memory members) {
        ProxyUpgradeRow[] memory rows = fullTransition.ctmProxyRows();
        address[] memory newReleaseMembers = _releaseMembers(CTMRelease(_m.newRelease).getManifest());
        address[] memory fromReleaseMembers = _releaseMembers(CTMRelease(_m.fromRelease).getManifest());
        assertTrue(_m.l2Plan.delegateComposer != address(0), "the fixture transition names a composer");
        assertEq(rows.length, 1, "one participating CTM-domain row");

        members = new address[](
            TRANSITION_FIXED_MEMBERS + 1 + rows.length + newReleaseMembers.length + fromReleaseMembers.length
        );
        uint256 next = 0;
        members[next++] = _m.upgradeEngine;
        members[next++] = _m.upgradeTimer;
        members[next++] = _m.l2Plan.delegateComposer;
        for (uint256 i = 0; i < rows.length; ++i) {
            members[next++] = rows[i].implNew;
        }
        for (uint256 i = 0; i < newReleaseMembers.length; ++i) {
            members[next++] = newReleaseMembers[i];
        }
        for (uint256 i = 0; i < fromReleaseMembers.length; ++i) {
            members[next++] = fromReleaseMembers[i];
        }
    }

    /// @dev Empties `_member`'s code and checks `validate()` refuses it with that member's own
    ///      diagnostic, then restores the state and checks the object validates again.
    function _assertCodelessMemberIsRefused(IValidatable _object, address _member) internal {
        assertTrue(_member.code.length != 0, "the fixture member must have code before it is emptied");

        uint256 snapshot = vm.snapshotState();
        vm.etch(_member, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, _member));
        _object.validate();
        assertTrue(vm.revertToState(snapshot), "restore the emptied member");

        _object.validate();
    }
}

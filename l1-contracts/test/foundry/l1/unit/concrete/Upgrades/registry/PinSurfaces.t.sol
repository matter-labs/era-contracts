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
import {RegistryCodehashMismatch, RegistryPinTargetHasNoCode} from "contracts/common/L1ContractErrors.sol";
import {
    CoreRegistryManifest,
    PinnedContract,
    ProxyUpgradeRow,
    ReleaseManifest,
    TransitionManifest
} from "contracts/upgrades/registry/RegistryTypes.sol";

/// @dev The two check surfaces every write-once registry object exposes, so one helper can drive
///      a release, a transition and a core registry alike.
interface IPinSurfaces {
    function validate() external view;

    function verifyAll() external view returns (bool);
}

/// @dev Two distinct implementations so a proxy row is a real `expectedOldImpl -> implNew` edge.
contract PinTargetOld {
    function version() external pure returns (uint256) {
        return 1;
    }
}

contract PinTargetNew {
    function version() external pure returns (uint256) {
        return 2;
    }
}

/// @notice `validate()` and `verifyAll()` are two surfaces over ONE pin list per object (see "Two
///         validation surfaces" in {docs/registry-driven-upgrades.md}). These tests enumerate
///         every pin a release, a transition and a core registry carry — the MANIFEST is the
///         spec, not the objects' code — and check that breaking any one of them flips BOTH
///         surfaces with that pin's own diagnostic, so no pin can be enforced by one surface and
///         missed by the other.
/// @dev The transition under test names every optional pin (a delegate composer, an ecosystem
///      leg, a participating CTM-domain row) so the full list is exercised.
contract PinSurfacesTest is CTMUpgradeExecutorFixture {
    /// @dev Distinct from every bytecode the fixture etches (`600042`, `600043`) so a drift is
    ///      always a real codehash change.
    bytes internal constant DRIFTED_CODE = hex"6000ff";
    /// @dev `diamondInit`, `genesisUpgrade`, `verifier` — the release pins that are not facets.
    uint256 internal constant RELEASE_FIXED_PINS = 3;
    /// @dev `upgradeEngine`, `upgradeTimer` — the transition pins every manifest carries.
    uint256 internal constant TRANSITION_FIXED_PINS = 2;

    address internal implOld;
    address internal implNew;
    CoreRegistry internal coreRegistry;
    /// @dev The fixture's default transition plus an ecosystem leg and one CTM-domain row.
    CTMTransition internal fullTransition;

    function setUp() public override {
        super.setUp();
        implOld = address(new PinTargetOld());
        implNew = address(new PinTargetNew());

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
        manifest.coreRegistry = _pin(address(coreRegistry));
        TransparentUpgradeableProxy ctmDomainProxy = new TransparentUpgradeableProxy(
            implOld,
            address(ctmProxyAdmin),
            hex""
        );
        manifest.proxyUpgrades[uint256(CTMContract.ValidatorTimelock)] = _row(address(ctmDomainProxy));
        fullTransition = new CTMTransition(manifest);
    }

    // ─────────────────────────────── happy path ───────────────────────────────

    function test_freshObjectsPassBothSurfaces() public view {
        _assertBothSurfacesPass(IPinSurfaces(address(release)));
        _assertBothSurfacesPass(IPinSurfaces(address(fullTransition)));
        _assertBothSurfacesPass(IPinSurfaces(address(coreRegistry)));
    }

    // ─────────────────────────────── every pin, both surfaces ───────────────────────────────

    function test_everyReleasePinFlipsBothSurfaces() public {
        PinnedContract[] memory pins = _releasePins(release.getManifest());
        assertEq(pins.length, RELEASE_FIXED_PINS + facetCuts.length, "the fixture release pins its full facet set");
        for (uint256 i = 0; i < pins.length; ++i) {
            _assertBreakingPinFlipsBothSurfaces(IPinSurfaces(address(release)), pins[i]);
        }
    }

    /// @dev A transition's list is its own pins plus BOTH release edges' lists: a drift on either
    ///      release must surface through the transition too.
    function test_everyTransitionPinFlipsBothSurfaces() public {
        PinnedContract[] memory pins = _transitionPins(fullTransition.getManifest());
        for (uint256 i = 0; i < pins.length; ++i) {
            _assertBreakingPinFlipsBothSurfaces(IPinSurfaces(address(fullTransition)), pins[i]);
        }
    }

    function test_everyCoreRegistryPinFlipsBothSurfaces() public {
        ProxyUpgradeRow[] memory rows = coreRegistry.ecosystemRows();
        assertEq(rows.length, 1, "one participating row");
        for (uint256 i = 0; i < rows.length; ++i) {
            _assertBreakingPinFlipsBothSurfaces(IPinSurfaces(address(coreRegistry)), rows[i].implNew);
        }
    }

    /// @dev Any drift of any transition pin, not only the fixed bytecode above.
    function testFuzz_anyTransitionPinDriftFlipsBothSurfaces(uint256 _pinIndex, bytes32 _salt) public {
        PinnedContract[] memory pins = _transitionPins(fullTransition.getManifest());
        PinnedContract memory pin = pins[bound(_pinIndex, 0, pins.length - 1)];
        bytes memory drifted = abi.encodePacked(_salt);
        vm.assume(keccak256(drifted) != pin.codehash);

        vm.etch(pin.addr, drifted);
        vm.expectRevert(
            abi.encodeWithSelector(RegistryCodehashMismatch.selector, pin.addr, pin.codehash, keccak256(drifted))
        );
        fullTransition.validate();
        assertFalse(fullTransition.verifyAll(), "a drifted pin must not verify");
    }

    // ─────────────────────────────── helpers ───────────────────────────────

    function _row(address _proxy) internal view returns (ProxyUpgradeRow memory) {
        return
            ProxyUpgradeRow({
                proxy: _proxy,
                expectedOldImpl: implOld,
                implNew: _pin(implNew),
                callInitializeUpgrade: false,
                admin: ProxyAdmin(address(0))
            });
    }

    /// @dev What a release pins, read off its manifest: DiamondInit, genesis upgrade, verifier,
    ///      every genesis facet.
    function _releasePins(ReleaseManifest memory _m) internal pure returns (PinnedContract[] memory pins) {
        pins = new PinnedContract[](RELEASE_FIXED_PINS + _m.genesisFacets.length);
        pins[0] = _m.diamondInit;
        pins[1] = _m.genesisUpgrade;
        pins[2] = _m.verifier;
        for (uint256 i = 0; i < _m.genesisFacets.length; ++i) {
            pins[RELEASE_FIXED_PINS + i] = _m.genesisFacets[i].facet;
        }
    }

    /// @dev What a transition pins, read off its manifest: engine, timer, composer, ecosystem
    ///      leg, every participating row's implementation, and both release edges' own lists.
    function _transitionPins(TransitionManifest memory _m) internal view returns (PinnedContract[] memory pins) {
        ProxyUpgradeRow[] memory rows = fullTransition.ctmProxyRows();
        PinnedContract[] memory newReleasePins = _releasePins(CTMRelease(_m.newRelease).getManifest());
        PinnedContract[] memory fromReleasePins = _releasePins(CTMRelease(_m.fromRelease).getManifest());
        assertTrue(_m.l2Plan.delegateComposer.addr != address(0), "the fixture transition pins a composer");
        assertTrue(_m.coreRegistry.addr != address(0), "the fixture transition names an ecosystem leg");
        assertEq(rows.length, 1, "one participating CTM-domain row");

        pins = new PinnedContract[](
            TRANSITION_FIXED_PINS + 2 + rows.length + newReleasePins.length + fromReleasePins.length
        );
        uint256 next = 0;
        pins[next++] = _m.upgradeEngine;
        pins[next++] = _m.upgradeTimer;
        pins[next++] = _m.l2Plan.delegateComposer;
        pins[next++] = _m.coreRegistry;
        for (uint256 i = 0; i < rows.length; ++i) {
            pins[next++] = rows[i].implNew;
        }
        for (uint256 i = 0; i < newReleasePins.length; ++i) {
            pins[next++] = newReleasePins[i];
        }
        for (uint256 i = 0; i < fromReleasePins.length; ++i) {
            pins[next++] = fromReleasePins[i];
        }
    }

    function _assertBothSurfacesPass(IPinSurfaces _object) internal view {
        _object.validate();
        assertTrue(_object.verifyAll(), "a fresh object must verify");
    }

    /// @dev Breaks `_pin` both ways a pin can break — drifted code and no code at all — and
    ///      checks both surfaces report it with the pin's own diagnostic, then restores the pin
    ///      and checks both surfaces pass again.
    function _assertBreakingPinFlipsBothSurfaces(IPinSurfaces _object, PinnedContract memory _pin) internal {
        assertEq(_pin.addr.codehash, _pin.codehash, "the fixture pin must hold before it is broken");

        uint256 snapshot = vm.snapshotState();
        vm.etch(_pin.addr, DRIFTED_CODE);
        vm.expectRevert(
            abi.encodeWithSelector(RegistryCodehashMismatch.selector, _pin.addr, _pin.codehash, keccak256(DRIFTED_CODE))
        );
        _object.validate();
        assertFalse(_object.verifyAll(), "a drifted pin must not verify");
        assertTrue(vm.revertToState(snapshot), "restore the drifted pin");

        snapshot = vm.snapshotState();
        vm.etch(_pin.addr, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryPinTargetHasNoCode.selector, _pin.addr));
        _object.validate();
        assertFalse(_object.verifyAll(), "a codeless pin must not verify");
        assertTrue(vm.revertToState(snapshot), "restore the codeless pin");

        _assertBothSurfacesPass(_object);
    }
}

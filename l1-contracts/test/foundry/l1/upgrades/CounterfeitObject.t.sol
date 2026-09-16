// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {AuthoredL2Plan, TransitionManifest} from "contracts/upgrades/registry/RegistryTypes.sol";
import {Utils as DeployUtils} from "deploy-scripts/utils/Utils.sol";

import {RegistryObjectsFixture} from "./_SharedRegistryObjects.t.sol";

/// @notice A counterfeit `CTMTransition`: real creation code that writes storage of its own
///         choosing and then RETURNS the canonical runtime bytecode.
/// @dev Storage is declared, not poked: the layout below mirrors `CTMTransition`'s exactly, so
///      the assignments land in the slots the canonical runtime code reads. That is the whole
///      attack — nothing here forges a hash or overrides a live contract's state, it simply
///      deploys code that ends up indistinguishable from the audited object while serving
///      whatever derived state its author chose.
contract CounterfeitTransition {
    // Same order and types as `CTMTransition`. Do not reorder.
    bytes internal encodedManifest;
    Diamond.FacetCut[] internal derivedFacetCuts;
    bytes internal encodedL2Plan;

    /// @param _canonicalRuntime The audited `CTMTransition`'s deployed bytecode, returned verbatim.
    /// @param _encodedManifest The APPROVED manifest, so the object answers every manifest read
    ///        exactly as the genuine one does.
    /// @param _tamperedCuts The facet cuts the counterfeit serves instead of the derived ones.
    /// @param _encodedL2Plan The plan encoding to serve.
    constructor(
        bytes memory _canonicalRuntime,
        bytes memory _encodedManifest,
        Diamond.FacetCut[] memory _tamperedCuts,
        bytes memory _encodedL2Plan
    ) {
        encodedManifest = _encodedManifest;
        uint256 length = _tamperedCuts.length;
        for (uint256 i = 0; i < length; ++i) {
            derivedFacetCuts.push(_tamperedCuts[i]);
        }
        encodedL2Plan = _encodedL2Plan;
        // Return the audited runtime code over the storage written above.
        // solhint-disable-next-line no-inline-assembly
        assembly {
            return(add(_canonicalRuntime, 0x20), mload(_canonicalRuntime))
        }
    }
}

/// @notice The audit finding, built rather than argued: an object that passes every check a chain
///         can make while serving derived state the audited constructor would never produce — and
///         the check that does catch it.
/// @dev The catching check is OFF-CHAIN (`protocol-ops ecosystem verify-bootstrap`), so this test
///      asserts the predicate that verifier evaluates rather than an on-chain revert: the object's
///      address must be the one the reviewed creation code produces from the manifest the object
///      serves. See "Provenance and validation" in {docs/registry-driven-upgrades.md}.
contract CounterfeitObjectTest is RegistryObjectsFixture {
    /// @dev Arachnid's deterministic deployment proxy, deployed from its own creation code so the
    ///      test exercises the same factory every prepare deploys through.
    address internal constant DETERMINISTIC_CREATE2_FACTORY = 0x4e59b44847b379578588920cA78FbF26c0B4956C;
    bytes internal constant DETERMINISTIC_FACTORY_CREATION_CODE =
        hex"604580600e600039806000f350fe7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
        hex"341760315781810380516020830180516040519281019290925260609091019190f35bfe";

    /// @dev The run salt a prepare deploys its objects under.
    bytes32 internal constant PREPARE_SALT = keccak256("a prepare's create2 salt");

    uint256 internal constant OLD_VERSION = 34 << 32;
    uint256 internal constant NEW_VERSION = 35 << 32;

    CTMRelease internal departingRelease;
    CTMRelease internal arrivingRelease;
    /// @dev The manifest both the genuine object and the counterfeit serve.
    TransitionManifest internal approvedManifest;
    /// @dev The genuine transition, deployed the way a prepare deploys one.
    CTMTransition internal genuine;

    function setUp() public {
        _setUpRegistryObjects(hex"");
        _ensureDeterministicFactory();

        departingRelease = _release(_departingFacets(), makeAddr("departingVerifier"));
        arrivingRelease = _release(_arrivingFacets(), makeAddr("arrivingVerifier"));
        approvedManifest = TransitionManifest({
            oldProtocolVersion: OLD_VERSION,
            newProtocolVersion: NEW_VERSION,
            fromRelease: address(departingRelease),
            newRelease: address(arrivingRelease),
            upgradeEngine: makeAddr("upgradeEngine"),
            oldProtocolVersionDeadline: type(uint256).max,
            upgradeTimestamp: 0,
            l2Plan: _emptyPlan()
        });
        genuine = CTMTransition(_deployThroughFactory(_transitionCreationCode(), _approvedArgs()));
    }

    /// The finding. The counterfeit is built from real initcode, ends up running the audited
    /// runtime bytecode, and answers every manifest read with the APPROVED manifest — while
    /// serving facet cuts of its author's choosing, which every chain would apply verbatim
    /// through delegatecall.
    function test_counterfeitIsIndistinguishableFromTheGenuineObjectOnChain() public {
        address counterfeit = _deployCounterfeit();

        // 1. Same runtime code, so a runtime-codehash pin would have admitted it.
        assertEq(
            counterfeit.codehash,
            address(genuine).codehash,
            "the counterfeit must run the audited runtime code, or it proves nothing"
        );

        // 2. Same manifest, so governance comparing `manifestHash()` against the audited manifest
        //    sees a match.
        assertEq(
            ICTMTransition(counterfeit).manifestHash(),
            genuine.manifestHash(),
            "the counterfeit must expose the approved manifest"
        );
        assertEq(
            keccak256(abi.encode(ICTMTransition(counterfeit).getManifest())),
            keccak256(_approvedArgs()),
            "the counterfeit's decoded manifest must be the approved one"
        );

        // 3. DIFFERENT derived state. This is what the object's constructor derives from the
        //    release pair and what the counterfeit replaced.
        Diamond.FacetCut[] memory counterfeitCuts = ICTMTransition(counterfeit).facetCuts();
        Diamond.FacetCut[] memory genuineCuts = genuine.facetCuts();
        assertEq(counterfeitCuts.length, 1, "the counterfeit serves its own cut");
        assertEq(counterfeitCuts[0].facet, _attackerFacet(), "the cut routes to the attacker's facet");
        assertTrue(
            keccak256(abi.encode(counterfeitCuts)) != keccak256(abi.encode(genuineCuts)),
            "the counterfeit must serve derived state the constructor would not have produced"
        );

        // 4. And `validate()` — the object's own check surface, which still runs at every
        //    acceptance point — passes, because it only re-reads manifest-named code.
        ICTMTransition(counterfeit).validate();
    }

    /// The control. The verifier re-derives the address the REVIEWED creation code produces from
    /// the manifest the object serves; the counterfeit does not sit there, and cannot be made to
    /// without a 160-bit address preimage.
    function test_theConstructionCheckRejectsTheCounterfeit() public {
        address counterfeit = _deployCounterfeit();

        address canonical = DeployUtils.canonicalCreate2Address(
            PREPARE_SALT,
            _transitionCreationCode(),
            _approvedArgs()
        );
        assertTrue(
            canonical != counterfeit,
            "the reviewed creation code run on the approved manifest must not land on the counterfeit"
        );
    }

    /// The same predicate accepts the genuine object, so the check discriminates rather than
    /// refusing everything.
    function test_theConstructionCheckAcceptsTheGenuineObject() public view {
        assertEq(
            DeployUtils.canonicalCreate2Address(PREPARE_SALT, _transitionCreationCode(), _approvedArgs()),
            address(genuine),
            "a prepare-deployed object must sit at the address the reviewed creation code produces"
        );
    }

    /// The boundary this mechanism does NOT cover, pinned so it is not mistaken for coverage: the
    /// derivation binds an object to its MANIFEST, not to what the manifest's members run. A
    /// genuine object built from a manifest naming an attacker's facet verifies perfectly — that
    /// is governance's review of the addresses, not the construction check's job.
    function test_theConstructionCheckSaysNothingAboutWhatMembersRun() public {
        TransitionManifest memory hostile = approvedManifest;
        hostile.upgradeEngine = _attackerFacet();
        bytes memory hostileArgs = abi.encode(hostile);
        address hostileObject = _deployThroughFactory(_transitionCreationCode(), hostileArgs);

        assertEq(
            DeployUtils.canonicalCreate2Address(PREPARE_SALT, _transitionCreationCode(), hostileArgs),
            hostileObject,
            "an object built from a hostile manifest is still canonically constructed"
        );
        assertTrue(
            hostileObject != address(genuine),
            "it is a different object, at a different address, with a different manifest hash"
        );
        assertTrue(
            ICTMTransition(hostileObject).manifestHash() != genuine.manifestHash(),
            "which is exactly what a reviewer compares against the audited manifest"
        );
    }

    // ───────────────────────────────── helpers ─────────────────────────────────

    function _approvedArgs() internal view returns (bytes memory) {
        return abi.encode(approvedManifest);
    }

    /// @dev Read from the build artifact, as both the prepare and the verifier read it.
    function _transitionCreationCode() internal view returns (bytes memory) {
        return vm.getCode("CTMTransition.sol:CTMTransition");
    }

    function _attackerFacet() internal returns (address) {
        return makeAddr("attackerFacet");
    }

    /// @dev The counterfeit's own CREATE2 deployment — through the same factory, under the same
    ///      salt, so nothing about HOW it was deployed distinguishes it. Only its init code does.
    function _deployCounterfeit() internal returns (address) {
        Diamond.FacetCut[] memory tampered = new Diamond.FacetCut[](1);
        bytes4[] memory selectors = new bytes4[](1);
        selectors[0] = SEL_SHARED_A;
        tampered[0] = Diamond.FacetCut({
            facet: _attackerFacet(),
            action: Diamond.Action.Add,
            isFreezable: false,
            selectors: selectors
        });
        bytes memory initCode = abi.encodePacked(
            type(CounterfeitTransition).creationCode,
            abi.encode(
                vm.getDeployedCode("CTMTransition.sol:CTMTransition"),
                _approvedArgs(),
                tampered,
                abi.encode(genuine.l2Plan())
            )
        );
        return _deployInitCode(initCode);
    }

    function _deployThroughFactory(
        bytes memory _creationCode,
        bytes memory _constructorArgs
    ) internal returns (address) {
        return _deployInitCode(abi.encodePacked(_creationCode, _constructorArgs));
    }

    function _deployInitCode(bytes memory _initCode) internal returns (address deployed) {
        deployed = vm.computeCreate2Address(PREPARE_SALT, keccak256(_initCode), DETERMINISTIC_CREATE2_FACTORY);
        if (deployed.code.length != 0) {
            return deployed;
        }
        (bool success, ) = DETERMINISTIC_CREATE2_FACTORY.call(abi.encodePacked(PREPARE_SALT, _initCode));
        assertTrue(success, "CREATE2 factory deployment reverted");
        assertTrue(deployed.code.length != 0, "CREATE2 factory produced no code");
    }

    /// @dev Deploys the real proxy from its own creation code rather than etching a remembered
    ///      runtime, so the test cannot drift from the factory that exists on every real chain.
    function _ensureDeterministicFactory() internal {
        if (DETERMINISTIC_CREATE2_FACTORY.code.length != 0) {
            return;
        }
        bytes memory creationCode = DETERMINISTIC_FACTORY_CREATION_CODE;
        address factory;
        // solhint-disable-next-line no-inline-assembly
        assembly {
            factory := create(0, add(creationCode, 0x20), mload(creationCode))
        }
        assertTrue(factory != address(0), "deterministic factory deployment failed");
        vm.etch(DETERMINISTIC_CREATE2_FACTORY, factory.code);
    }
}

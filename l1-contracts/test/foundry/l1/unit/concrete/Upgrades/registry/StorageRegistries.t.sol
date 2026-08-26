// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {CoreRegistry} from "contracts/upgrades/registry/CoreRegistry.sol";
import {EcosystemContractRow} from "contracts/upgrades/registry/ICoreRegistry.sol";
import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/CTMTransition.sol";
import {ICTMTransition, L2UpgradePlan} from "contracts/upgrades/registry/ICTMTransition.sol";
import {ICTMRelease, GenesisFacet} from "contracts/upgrades/registry/ICTMRelease.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/CTMUpgradeComposer.sol";
import {ReleaseFacetReader} from "contracts/upgrades/registry/ReleaseFacetReader.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {DiamondInit} from "contracts/state-transition/chain-deps/DiamondInit.sol";
import {IComplexUpgrader} from "contracts/state-transition/l2-deps/IComplexUpgrader.sol";
import {ProposedUpgrade} from "contracts/state-transition/libraries/ProposedUpgradeLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {
    MAX_ALLOWED_MINOR_VERSION_DELTA,
    MAX_NEW_FACTORY_DEPS,
    ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE
} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    MalformedL2UpgradePlan,
    PatchMustReuseRelease,
    RegistryCodehashMismatch,
    RegistryDuplicateFacetRow,
    RegistryDuplicateProxyRow,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    RegistryHashChangeToZero,
    RegistryPinTargetHasNoCode,
    SameReleaseTransitionHasPayload,
    TransitionDeadlineBeforeUpgrade,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    NewProtocolMajorVersionNotZero,
    ProtocolVersionMinorDeltaTooBig,
    ProtocolVersionTooSmall
} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";

/// @notice Unit tests for the write-once upgrade objects in the DERIVED model: releases carry
///         explicit routing + inline mandatory pins; transitions derive their facet/hash delta
///         from the `(fromRelease, newRelease)` pair at initialization.
contract StorageRegistriesTest is Test {
    CoreRegistry internal coreRegistry;
    CTMRelease internal fromRelease;
    CTMRelease internal newRelease;
    CTMTransition internal transition;

    address internal diamondInit;

    // Pinned synthetic contracts (etched with distinct bytecode so codehash pins are real).
    address internal facetOldAdmin; // replaced by the hop
    address internal facetNewAdmin; // its replacement (different selectors)
    address internal facetShared; // carried over unchanged
    address internal facetFrozen; // carried over unchanged, freezable
    address internal genesisUpgrade;
    address internal verifier;
    address internal upgradeEngine;
    address internal coreImplNew;

    uint256 internal constant OLD_VERSION = uint256(98) << 32;
    uint256 internal constant NEW_VERSION = uint256(99) << 32;

    bytes32 internal constant BOOTLOADER_FROM = bytes32(uint256(0xb00));
    bytes32 internal constant BOOTLOADER_NEW = bytes32(uint256(0xbb0));
    bytes32 internal constant DEFAULT_ACCOUNT_HASH = bytes32(uint256(0xda0));

    function setUp() public {
        facetOldAdmin = _pinned("facetOldAdmin");
        facetNewAdmin = _pinned("facetNewAdmin");
        facetShared = _pinned("facetShared");
        facetFrozen = _pinned("facetFrozen");
        genesisUpgrade = _pinned("genesisUpgrade");
        verifier = _pinned("verifier");
        upgradeEngine = _pinned("upgradeEngine");
        coreImplNew = _pinned("coreImplNew");
        // A real DiamondInit: VM identity is read from its IS_ZKSYNC_OS immutable.
        diamondInit = address(new DiamondInit(true));

        coreRegistry = new CoreRegistry(_coreManifest());
        // Releases deploy through the canonical factory: transition initialization enforces
        // factory provenance on BOTH edges.
        fromRelease = new CTMRelease(_fromReleaseManifest());
        newRelease = new CTMRelease(_newReleaseManifest());
        transition = new CTMTransition(_transitionManifest());
    }

    /// @dev Deploys a distinct-bytecode stand-in at a labelled address so EXTCODEHASH pins are
    ///      real (an empty address would pin the zero hash).
    function _pinned(string memory _name) internal returns (address addr) {
        addr = makeAddr(_name);
        vm.etch(addr, bytes.concat(hex"00", bytes(_name)));
    }

    function _coreManifest() internal view returns (CoreRegistry.CoreRegistryManifest memory manifest) {
        // A single full source-checked edge — every core row must be a real, unique edge;
        // placeholder (all-zero) rows are rejected at the registry boundary.
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](1);
        rows[0] = EcosystemContractRow({
            proxy: address(0xB001),
            expectedOldImpl: address(0xB101),
            implNew: coreImplNew,
            implNewCodehash: coreImplNew.codehash
        });
        return CoreRegistry.CoreRegistryManifest({contractRows: rows});
    }

    function _releaseManifest(
        address _adminFacet,
        bytes4[] memory _adminSelectors,
        bytes32 _bootloaderHash
    ) internal view returns (CTMRelease.ReleaseManifest memory manifest) {
        GenesisFacet[] memory facets = new GenesisFacet[](3);
        facets[0] = GenesisFacet({
            facet: _adminFacet,
            isFreezable: false,
            selectors: _adminSelectors,
            codehash: _adminFacet.codehash
        });
        facets[1] = GenesisFacet({
            facet: facetShared,
            isFreezable: false,
            selectors: _selectors2(bytes4(uint32(0x10)), bytes4(uint32(0x11))),
            codehash: facetShared.codehash
        });
        facets[2] = GenesisFacet({
            facet: facetFrozen,
            isFreezable: true,
            selectors: _selectors1(bytes4(uint32(0x20))),
            codehash: facetFrozen.codehash
        });
        return
            CTMRelease.ReleaseManifest({
                diamondInit: diamondInit,
                diamondInitCodehash: diamondInit.codehash,
                verifier: verifier,
                verifierCodehash: verifier.codehash,
                genesisFacets: facets,
                bootloaderHash: _bootloaderHash,
                defaultAccountHash: DEFAULT_ACCOUNT_HASH,
                evmEmulatorHash: bytes32(0),
                fixedForceDeploymentsData: hex"f1f2",
                genesisUpgrade: genesisUpgrade,
                genesisUpgradeCodehash: genesisUpgrade.codehash,
                genesisBatchHash: bytes32(uint256(1)),
                genesisBatchCommitment: bytes32(uint256(1)),
                genesisIndexRepeatedStorageChanges: 54
            });
    }

    function _fromReleaseManifest() internal view returns (CTMRelease.ReleaseManifest memory) {
        return _releaseManifest(facetOldAdmin, _selectors2(bytes4(uint32(1)), bytes4(uint32(2))), BOOTLOADER_FROM);
    }

    function _newReleaseManifest() internal view returns (CTMRelease.ReleaseManifest memory) {
        // The hop replaces the admin facet (new address AND new selector set) and bumps the
        // bootloader hash; the shared + frozen facets carry over unchanged.
        return _releaseManifest(facetNewAdmin, _selectors2(bytes4(uint32(2)), bytes4(uint32(3))), BOOTLOADER_NEW);
    }

    function _l2Plan() internal pure returns (L2UpgradePlan memory plan) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](2);
        deployments[0] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
            deployedBytecodeInfo: hex"aa01",
            newAddress: address(0x10002)
        });
        deployments[1] = IComplexUpgrader.UniversalContractUpgradeInfo({
            upgradeType: IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade,
            deployedBytecodeInfo: hex"aa02",
            newAddress: address(0x10003)
        });
        uint256[] memory factoryDeps = new uint256[](2);
        factoryDeps[0] = 1;
        factoryDeps[1] = 2;
        return
            L2UpgradePlan({
                deployments: deployments,
                delegateTo: address(0x10004),
                delegateCalldata: hex"beef",
                factoryDepHashes: factoryDeps
            });
    }

    function _transitionManifest() internal view returns (CTMTransition.TransitionManifest memory manifest) {
        return
            CTMTransition.TransitionManifest({
                oldProtocolVersion: OLD_VERSION,
                newProtocolVersion: NEW_VERSION,
                fromRelease: address(fromRelease),
                newRelease: address(newRelease),
                upgradeEngine: upgradeEngine,
                upgradeEngineCodehash: upgradeEngine.codehash,
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeTimestamp: 1234567,
                l2Plan: _l2Plan()
            });
    }

    function _selectors1(bytes4 _a) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](1);
        selectors[0] = _a;
    }

    function _selectors2(bytes4 _a, bytes4 _b) internal pure returns (bytes4[] memory selectors) {
        selectors = new bytes4[](2);
        selectors[0] = _a;
        selectors[1] = _b;
    }

    // ─────────────────────────── write-once + lookups ───────────────────────────

    function test_manifestsAreCommitted() public view {
        assertEq(coreRegistry.manifestHash(), keccak256(abi.encode(_coreManifest())));
        assertEq(newRelease.manifestHash(), keccak256(abi.encode(_newReleaseManifest())));
        assertEq(transition.manifestHash(), keccak256(abi.encode(_transitionManifest())));
    }

    function test_releasePinsPostUpgradeGenesis() public view {
        // The version schedule is a transition concern; the verifier is installed chain state and
        // therefore lives on the release, so both paths resolve it from the same object.
        assertEq(transition.newProtocolVersion(), NEW_VERSION);
        assertEq(newRelease.verifier(), verifier);
        assertEq(newRelease.diamondInit(), diamondInit);
        assertEq(newRelease.fixedForceDeploymentsData(), hex"f1f2");
        Diamond.FacetCut[] memory installations = ReleaseFacetReader.newChainInstallations(
            ICTMRelease(address(newRelease))
        );
        assertEq(installations.length, 3);
        assertEq(installations[0].facet, facetNewAdmin);
        assertEq(installations[0].selectors.length, 2);
        assertEq(installations[2].facet, facetFrozen);
        assertTrue(installations[2].isFreezable);
    }

    // ─────────────────────────── derived delta ───────────────────────────

    function test_transitionDerivesFacetDeltaFromReleasePair() public view {
        assertEq(transition.oldProtocolVersion(), OLD_VERSION);
        assertEq(transition.fromRelease(), address(fromRelease));
        assertEq(transition.newRelease(), address(newRelease));
        assertEq(transition.upgradeEngine(), upgradeEngine);

        // Derived, not authored — and stored as final cuts: one Remove cut (the departing admin
        // facet's full routing, facet address zero per Diamond semantics) followed by one Add
        // cut (its replacement); carried-over facets contribute nothing, and there is no
        // Replace bucket by construction.
        Diamond.FacetCut[] memory derivedCuts = transition.facetCuts();
        assertEq(derivedCuts.length, 2);
        assertEq(derivedCuts[0].facet, address(0));
        assertTrue(derivedCuts[0].action == Diamond.Action.Remove);
        assertEq(derivedCuts[0].selectors.length, 2);
        assertEq(derivedCuts[1].facet, facetNewAdmin);
        assertTrue(derivedCuts[1].action == Diamond.Action.Add);
        assertEq(derivedCuts[1].selectors.length, 2);
        assertFalse(derivedCuts[1].isFreezable);

        // Hash changes derived the same way: only the bootloader differs between the releases.
        (bytes32 bootloaderChange, bytes32 defaultAccountChange, bytes32 evmEmulatorChange) = transition
            .baseSystemContractHashChanges();
        assertEq(bootloaderChange, BOOTLOADER_NEW);
        assertEq(defaultAccountChange, bytes32(0));
        assertEq(evmEmulatorChange, bytes32(0));
    }

    function test_composerBuildsL2TxAndProposalFromTransition() public view {
        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(transition))
        );
        // VM identity single-source: the target release's DiamondInit was built with true.
        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE);
        assertEq(transaction.from, uint256(uint160(L2_FORCE_DEPLOYER_ADDR)));
        assertEq(transaction.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)));
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(NEW_VERSION));
        assertEq(transaction.nonce, minor);
        assertEq(transaction.factoryDeps.length, 2);

        ProposedUpgrade memory proposedUpgrade = CTMUpgradeComposer.buildProposedUpgrade(
            ICTMTransition(address(transition))
        );
        assertEq(proposedUpgrade.newProtocolVersion, NEW_VERSION);
        assertEq(proposedUpgrade.upgradeTimestamp, 1234567);
        assertEq(proposedUpgrade.bootloaderHash, BOOTLOADER_NEW);
    }

    /// @dev Regression: a delegate-only L2 plan (no force-deployments) must still compose a
    ///      transaction — previously such committed data was silently discarded.
    function test_composerBuildsDelegateOnlyL2Tx() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
        manifest.l2Plan.factoryDepHashes = new uint256[](0);
        CTMTransition delegateOnly = new CTMTransition(manifest);

        L2CanonicalTransaction memory transaction = CTMUpgradeComposer.buildL2UpgradeTx(
            ICTMTransition(address(delegateOnly))
        );
        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE, "delegate-only plan must compose a tx");
        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (manifest.l2Plan.deployments, address(0x10004), hex"beef")
            )
        );
    }

    // ─────────────────────────── patches / same-release ───────────────────────────

    /// @dev A verifier/schedule-only SemVer patch: same release on both edges, +1 patch
    ///      version, and NO L2 payload — the only shape a same-release hop may take.
    function _patchManifest() internal view returns (CTMTransition.TransitionManifest memory manifest) {
        manifest = _transitionManifest();
        manifest.oldProtocolVersion = NEW_VERSION;
        manifest.newProtocolVersion = NEW_VERSION + 1;
        manifest.fromRelease = address(newRelease);
        manifest.l2Plan = L2UpgradePlan({
            deployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
            delegateTo: address(0),
            delegateCalldata: "",
            factoryDepHashes: new uint256[](0)
        });
    }

    function test_patchTransitionVerifierOnlyInitializes() public {
        CTMTransition patchTransition = new CTMTransition(_patchManifest());
        assertEq(patchTransition.fromRelease(), patchTransition.newRelease());
        // The derived delta of a same-release hop is empty by construction.
        assertEq(patchTransition.facetCuts().length, 0);
        (bytes32 bootloaderChange, , ) = patchTransition.baseSystemContractHashChanges();
        assertEq(bootloaderChange, bytes32(0));
        // Both edges are live releases, so runtime validation holds.
        patchTransition.validate();
        assertTrue(patchTransition.verifyAll());
    }

    function test_revertWhen_sameReleaseTransitionCarriesL2Payload() public {
        CTMTransition.TransitionManifest memory manifest = _patchManifest();
        manifest.l2Plan.delegateTo = address(0x10004);

        vm.expectRevert(SameReleaseTransitionHasPayload.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_patchTargetsDifferentRelease() public {
        CTMTransition.TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);

        vm.expectRevert(
            abi.encodeWithSelector(PatchMustReuseRelease.selector, address(fromRelease), address(newRelease))
        );
        new CTMTransition(manifest);
    }

    // ─────────────────────────── schedule / version guards ───────────────────────────

    function test_revertWhen_transitionVersionNotIncreasing() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.newProtocolVersion = manifest.oldProtocolVersion;

        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector, OLD_VERSION, OLD_VERSION));
        new CTMTransition(manifest);
    }

    /// @dev Regression: two rows for the SAME facet address are rejected. `Diamond._addOneFunction`
    ///      requires every selector of one facet to share freezability, so a split-row release would
    ///      pin fine and then revert at genesis (and in any cut that adds it).
    function test_revertWhen_releaseSplitsOneFacetAcrossRows() public {
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        // Re-point the frozen row at the shared facet, keeping its distinct selectors: same facet
        // address in two rows, with DIFFERENT freezability.
        manifest.genesisFacets[2].facet = facetShared;
        manifest.genesisFacets[2].codehash = facetShared.codehash;

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateFacetRow.selector, facetShared));
        new CTMRelease(manifest);
    }

    /// @dev Regression: the transition must enforce the SAME version shape chains enforce at
    ///      execution (`BaseZkSyncUpgrade._setNewProtocolVersion`). Otherwise the transition pins,
    ///      `applyCTMUpgrade` bumps the CTM, and every per-chain upgrade then reverts.
    function test_revertWhen_transitionUsesNonzeroMajorVersion() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        // major = 1 — rejected per-chain, so it must be rejected at pin time too.
        manifest.newProtocolVersion = SemVer.packSemVer(1, 0, 0);

        vm.expectRevert(NewProtocolMajorVersionNotZero.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_transitionMinorDeltaTooBig() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        (, uint32 oldMinor, ) = SemVer.unpackSemVer(uint96(manifest.oldProtocolVersion));
        uint32 tooFar = oldMinor + uint32(MAX_ALLOWED_MINOR_VERSION_DELTA) + 1;
        manifest.newProtocolVersion = SemVer.packSemVer(0, tooFar, 0);

        vm.expectRevert(
            abi.encodeWithSelector(
                ProtocolVersionMinorDeltaTooBig.selector,
                MAX_ALLOWED_MINOR_VERSION_DELTA,
                uint256(tooFar - oldMinor)
            )
        );
        new CTMTransition(manifest);
    }

    /// @dev Regression: a plan carrying more factory deps than `BaseZkSyncUpgrade` accepts must be
    ///      rejected at pin time. Otherwise `applyCTMUpgrade` bumps the CTM version and every
    ///      per-chain upgrade then reverts, stranding chains on an unexecutable transition.
    function test_revertWhen_transitionExceedsFactoryDepCap() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        uint256[] memory tooManyDeps = new uint256[](MAX_NEW_FACTORY_DEPS + 1);
        for (uint256 i = 0; i < tooManyDeps.length; ++i) {
            tooManyDeps[i] = i + 1;
        }
        manifest.l2Plan.factoryDepHashes = tooManyDeps;

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    /// @dev Regression: a target release that blanks a base-system hash (nonzero -> zero) cannot be
    ///      executed as an upgrade, because `BaseZkSyncUpgrade` reads a zero change as "leave
    ///      unchanged". Existing chains would keep the old hash while fresh chains take the release
    ///      value, so the derivation rejects it instead of storing a silent no-op.
    function test_revertWhen_transitionBlanksBaseSystemHash() public {
        // A target release identical to the source except that the bootloader hash goes to zero.
        CTMRelease.ReleaseManifest memory blankingManifest = _releaseManifest(
            facetNewAdmin,
            _selectors2(bytes4(uint32(2)), bytes4(uint32(3))),
            bytes32(0)
        );
        CTMRelease blankingRelease = new CTMRelease(blankingManifest);

        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(blankingRelease);

        vm.expectRevert(RegistryHashChangeToZero.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_deadlineBeforeUpgradeTimestamp() public {
        // A deadline before the upgrade timestamp would disable the old protocol before chains
        // are even allowed to upgrade.
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.oldProtocolVersionDeadline = manifest.upgradeTimestamp - 1;

        vm.expectRevert(
            abi.encodeWithSelector(
                TransitionDeadlineBeforeUpgrade.selector,
                manifest.upgradeTimestamp - 1,
                manifest.upgradeTimestamp
            )
        );
        new CTMTransition(manifest);
    }

    function test_revertWhen_fromReleaseZero() public {
        // Pre-registry migration is one-time migration code in the legacy scripts, not a
        // permanent zero-source special case.
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.fromRelease = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── L2 plan shape ───────────────────────────

    function test_revertWhen_delegateCalldataWithoutTarget() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateTo = address(0);
        // delegateCalldata stays "beef" — data the composed tx would never execute.

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        CTMTransition malformed = new CTMTransition(manifest);
    }

    function test_revertWhen_factoryDepsWithoutL2Side() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
        manifest.l2Plan.delegateTo = address(0);
        manifest.l2Plan.delegateCalldata = "";
        // factoryDepHashes stay non-empty with no transaction to ride in.

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        CTMTransition malformed = new CTMTransition(manifest);
    }

    function test_revertWhen_deploymentsWithoutDelegateTarget() public {
        // Force-deployments but no delegate target: `L2ComplexUpgrader` always ends with the final
        // delegatecall, so a deployments-only plan would initialize here yet revert on L2 forever.
        // (delegateCalldata is cleared so ONLY the deployments-without-target rule can fire.)
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateTo = address(0);
        manifest.l2Plan.delegateCalldata = "";

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── routing hygiene ───────────────────────────

    function test_revertWhen_releaseRowHasEmptySelectors() public {
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].selectors = new bytes4[](0);

        vm.expectRevert(abi.encodeWithSelector(RegistryEmptySelectors.selector, facetShared));
        new CTMRelease(manifest);
    }

    function test_revertWhen_releaseHasNoFacets() public {
        // A release IS a complete chain routing: an empty facet set describes an unusable chain
        // and would derive a remove-everything delta. Rejected at the release boundary.
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets = new GenesisFacet[](0);

        vm.expectRevert(abi.encodeWithSelector(RegistryEmptySelectors.selector, address(0)));
        CTMRelease empty = new CTMRelease(manifest);
    }

    function test_revertWhen_releasePinsCodelessFacet() public {
        // A codehash pin must be over ACTUAL code: an address with no code is not a real
        // implementation (its EXTCODEHASH is zero / the empty-code hash), so pinning it is refused.
        address codeless = makeAddr("codelessFacet");
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[0].facet = codeless;
        manifest.genesisFacets[0].codehash = codeless.codehash;

        vm.expectRevert(abi.encodeWithSelector(RegistryPinTargetHasNoCode.selector, codeless));
        new CTMRelease(manifest);
    }

    function test_revertWhen_releaseRoutesSelectorTwice() public {
        // A release validates its OWN routing: a selector routed twice is rejected at release
        // initialization — the release boundary, before any transition ever derives from it.
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].selectors[0] = bytes4(uint32(0x20)); // collides with facetFrozen

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateSelector.selector, bytes4(uint32(0x20))));
        new CTMRelease(manifest);
    }

    // ─────────────────────────── factory provenance ───────────────────────────

    function test_transitionDefersReleaseProvenanceToCtm() public {
        // Release PROVENANCE is deliberately NOT a transition concern: a permissionless manifest
        // could name any "factory", so the transition only validates each edge's routing/pins and
        // leaves attestation to the CTM's canonical `releaseFactory` (enforced when the release
        // becomes `currentRelease` — see the CTM-level provenance test). So a hand-deployed but
        // VALID release is accepted here and derives a normal delta.
        CTMRelease handDeployed = new CTMRelease(_newReleaseManifest());

        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(handDeployed);

        CTMTransition deferred = new CTMTransition(manifest);
        assertEq(deferred.newRelease(), address(handDeployed), "transition accepts a valid hand-deployed release");
    }

    // ─────────────────────────── pins ───────────────────────────

    function test_revertWhen_transitionPinMismatch() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.upgradeEngineCodehash = keccak256("not the engine's code");

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                upgradeEngine,
                keccak256("not the engine's code"),
                upgradeEngine.codehash
            )
        );
        CTMTransition mispinned = new CTMTransition(manifest);
    }

    /// @dev The verifier pin moved to the release along with the verifier itself.
    function test_revertWhen_releaseVerifierPinMismatch() public {
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.verifierCodehash = keccak256("not the verifier's code");

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                verifier,
                keccak256("not the verifier's code"),
                verifier.codehash
            )
        );
        new CTMRelease(manifest);
    }

    function test_validateRejectsCodehashDrift() public {
        coreRegistry.validate();
        assertTrue(coreRegistry.verifyAll());
        newRelease.validate();
        transition.validate();
        assertTrue(transition.verifyAll());

        // Drift one pinned facet of the FROM release: release, and transitively the transition
        // (which validates both edges), must stop verifying.
        vm.etch(facetOldAdmin, hex"600042");
        vm.expectPartialRevert(RegistryCodehashMismatch.selector);
        fromRelease.validate();
        assertFalse(fromRelease.verifyAll());
        vm.expectPartialRevert(RegistryCodehashMismatch.selector);
        transition.validate();
        assertFalse(transition.verifyAll());

        // Same for the core registry's pinned implementation.
        vm.etch(coreImplNew, hex"600042");
        vm.expectPartialRevert(RegistryCodehashMismatch.selector);
        coreRegistry.validate();
        assertFalse(coreRegistry.verifyAll());
    }

    // ─────────────────────────── core registry rows ───────────────────────────

    function test_revertWhen_upgradingRowMissingSource() public {
        // A row that upgrades must be a full edge: known source implementation.
        CoreRegistry.CoreRegistryManifest memory manifest = _coreManifest();
        manifest.contractRows[0].expectedOldImpl = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new CoreRegistry(manifest);
    }

    function test_revertWhen_coreRegistryRowHasNoImplementation() public {
        // Every core row is a real edge — a placeholder that pins no new implementation
        // (implNew == 0) is refused; the old "skip zero rows" behavior is gone.
        CoreRegistry.CoreRegistryManifest memory manifest = _coreManifest();
        manifest.contractRows[0].implNew = address(0);
        manifest.contractRows[0].implNewCodehash = bytes32(0);

        vm.expectRevert(ZeroAddress.selector);
        new CoreRegistry(manifest);
    }

    function test_revertWhen_coreRegistryHasDuplicateProxyRow() public {
        // A proxy is routed once: two rows naming the same proxy are rejected.
        CoreRegistry.CoreRegistryManifest memory manifest = _coreManifest();
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](2);
        rows[0] = manifest.contractRows[0];
        rows[1] = manifest.contractRows[0]; // same proxy again
        manifest.contractRows = rows;

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateProxyRow.selector, rows[0].proxy));
        new CoreRegistry(manifest);
    }
}

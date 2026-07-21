// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L1EcosystemContract} from "contracts/upgrades/registry/ContractIdentifiers.sol";
import {CoreRegistry} from "contracts/upgrades/registry/CoreRegistry.sol";
import {EcosystemContractRow} from "contracts/upgrades/registry/ICoreRegistry.sol";
import {CTMRelease} from "contracts/upgrades/registry/CTMRelease.sol";
import {CTMReleaseFactory} from "contracts/upgrades/registry/CTMRegistryFactory.sol";
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
import {ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE} from "contracts/common/Config.sol";
import {L2_COMPLEX_UPGRADER_ADDR, L2_FORCE_DEPLOYER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {
    MalformedL2UpgradePlan,
    NotFactoryDeployed,
    PatchMustReuseRelease,
    RegistryAlreadyInitialized,
    RegistryCodehashMismatch,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    SameReleaseTransitionHasPayload,
    TransitionDeadlineBeforeUpgrade,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {ProtocolVersionTooSmall} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";

/// @notice Unit tests for the write-once upgrade objects in the DERIVED model: releases carry
///         explicit routing + inline mandatory pins; transitions derive their facet/hash delta
///         from the `(fromRelease, newRelease)` pair at initialization.
contract StorageRegistriesTest is Test {
    CoreRegistry internal coreRegistry;
    CTMReleaseFactory internal releaseFactory;
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

        coreRegistry = new CoreRegistry();
        coreRegistry.initialize(_coreManifest());
        // Releases deploy through the canonical factory: transition initialization enforces
        // factory provenance on BOTH edges.
        releaseFactory = new CTMReleaseFactory();
        fromRelease = CTMRelease(releaseFactory.deployOrGetRelease(_fromReleaseManifest()));
        newRelease = CTMRelease(releaseFactory.deployOrGetRelease(_newReleaseManifest()));
        transition = new CTMTransition();
        transition.initialize(_transitionManifest());
    }

    /// @dev Deploys a distinct-bytecode stand-in at a labelled address so EXTCODEHASH pins are
    ///      real (an empty address would pin the zero hash).
    function _pinned(string memory _name) internal returns (address addr) {
        addr = makeAddr(_name);
        vm.etch(addr, bytes.concat(hex"00", bytes(_name)));
    }

    function _coreManifest() internal view returns (CoreRegistry.CoreRegistryManifest memory manifest) {
        EcosystemContractRow[] memory rows = new EcosystemContractRow[](2);
        // A full source-checked edge...
        rows[0] = EcosystemContractRow({
            proxy: address(0xB001),
            expectedOldImpl: address(0xB101),
            implNew: coreImplNew,
            implNewCodehash: coreImplNew.codehash
        });
        // ...and a no-op placeholder row (nothing to upgrade).
        rows[1] = EcosystemContractRow({
            proxy: address(0xB003),
            expectedOldImpl: address(0),
            implNew: address(0),
            implNewCodehash: bytes32(0)
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
                releaseFactory: address(releaseFactory),
                oldProtocolVersion: OLD_VERSION,
                newProtocolVersion: NEW_VERSION,
                verifier: verifier,
                verifierCodehash: verifier.codehash,
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

    function test_manifestsAreWriteOnceAndCommitted() public {
        assertEq(coreRegistry.manifestHash(), keccak256(abi.encode(_coreManifest())));
        assertEq(newRelease.manifestHash(), keccak256(abi.encode(_newReleaseManifest())));
        assertEq(transition.manifestHash(), keccak256(abi.encode(_transitionManifest())));

        vm.expectRevert(RegistryAlreadyInitialized.selector);
        newRelease.initialize(_newReleaseManifest());
        vm.expectRevert(RegistryAlreadyInitialized.selector);
        transition.initialize(_transitionManifest());
    }

    function test_releasePinsPostUpgradeGenesis() public view {
        // Version + verifier are transition (version-schedule) concerns, not release concerns.
        assertEq(transition.newProtocolVersion(), NEW_VERSION);
        assertEq(transition.verifier(), verifier);
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
        CTMTransition delegateOnly = new CTMTransition();
        delegateOnly.initialize(manifest);

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
        CTMTransition patchTransition = new CTMTransition();
        patchTransition.initialize(_patchManifest());
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

        CTMTransition sameReleaseTransition = new CTMTransition();
        vm.expectRevert(SameReleaseTransitionHasPayload.selector);
        sameReleaseTransition.initialize(manifest);
    }

    function test_revertWhen_patchTargetsDifferentRelease() public {
        CTMTransition.TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);

        CTMTransition patchTransition = new CTMTransition();
        vm.expectRevert(
            abi.encodeWithSelector(PatchMustReuseRelease.selector, address(fromRelease), address(newRelease))
        );
        patchTransition.initialize(manifest);
    }

    // ─────────────────────────── schedule / version guards ───────────────────────────

    function test_revertWhen_transitionVersionNotIncreasing() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.newProtocolVersion = manifest.oldProtocolVersion;

        CTMTransition staleTransition = new CTMTransition();
        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector, OLD_VERSION, OLD_VERSION));
        staleTransition.initialize(manifest);
    }

    function test_revertWhen_deadlineBeforeUpgradeTimestamp() public {
        // A deadline before the upgrade timestamp would disable the old protocol before chains
        // are even allowed to upgrade.
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.oldProtocolVersionDeadline = manifest.upgradeTimestamp - 1;

        CTMTransition bricked = new CTMTransition();
        vm.expectRevert(
            abi.encodeWithSelector(
                TransitionDeadlineBeforeUpgrade.selector,
                manifest.upgradeTimestamp - 1,
                manifest.upgradeTimestamp
            )
        );
        bricked.initialize(manifest);
    }

    function test_revertWhen_fromReleaseZero() public {
        // Pre-registry migration is one-time migration code in the legacy scripts, not a
        // permanent zero-source special case.
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.fromRelease = address(0);

        CTMTransition migrationish = new CTMTransition();
        vm.expectRevert(ZeroAddress.selector);
        migrationish.initialize(manifest);
    }

    // ─────────────────────────── L2 plan shape ───────────────────────────

    function test_revertWhen_delegateCalldataWithoutTarget() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateTo = address(0);
        // delegateCalldata stays "beef" — data the composed tx would never execute.

        CTMTransition malformed = new CTMTransition();
        vm.expectRevert(MalformedL2UpgradePlan.selector);
        malformed.initialize(manifest);
    }

    function test_revertWhen_factoryDepsWithoutL2Side() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.deployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
        manifest.l2Plan.delegateTo = address(0);
        manifest.l2Plan.delegateCalldata = "";
        // factoryDepHashes stay non-empty with no transaction to ride in.

        CTMTransition malformed = new CTMTransition();
        vm.expectRevert(MalformedL2UpgradePlan.selector);
        malformed.initialize(manifest);
    }

    // ─────────────────────────── routing hygiene ───────────────────────────

    function test_revertWhen_releaseRowHasEmptySelectors() public {
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].selectors = new bytes4[](0);

        CTMRelease sparse = new CTMRelease();
        vm.expectRevert(abi.encodeWithSelector(RegistryEmptySelectors.selector, facetShared));
        sparse.initialize(manifest);
    }

    function test_revertWhen_releaseRoutesSelectorTwice() public {
        // The duplicate is caught when a transition derives from the malformed release (which
        // must still be factory-deployed — provenance is checked before derivation).
        CTMRelease.ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].selectors[0] = bytes4(uint32(0x20)); // collides with facetFrozen

        address malformed = releaseFactory.deployOrGetRelease(manifest);

        CTMTransition.TransitionManifest memory transitionManifest = _transitionManifest();
        transitionManifest.newRelease = malformed;
        CTMTransition duplicated = new CTMTransition();
        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateSelector.selector, bytes4(uint32(0x20))));
        duplicated.initialize(transitionManifest);
    }

    // ─────────────────────────── factory provenance ───────────────────────────

    function test_revertWhen_transitionReleaseNotFactoryDeployed() public {
        // Genuine CTMRelease code, correctly initialized — but hand-deployed, so the canonical
        // factory never attested it. A transition must refuse both edges like that: otherwise an
        // arbitrary (possibly mutable) `ICTMRelease` implementation could feed the derivation
        // and later serve genesis data via `currentRelease`.
        CTMRelease handDeployed = new CTMRelease();
        handDeployed.initialize(_newReleaseManifest());

        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(handDeployed);

        CTMTransition unattested = new CTMTransition();
        vm.expectRevert(abi.encodeWithSelector(NotFactoryDeployed.selector, address(handDeployed)));
        unattested.initialize(manifest);
    }

    // ─────────────────────────── pins ───────────────────────────

    function test_revertWhen_transitionPinMismatch() public {
        CTMTransition.TransitionManifest memory manifest = _transitionManifest();
        manifest.verifierCodehash = keccak256("not the verifier's code");

        CTMTransition mispinned = new CTMTransition();
        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                verifier,
                keccak256("not the verifier's code"),
                verifier.codehash
            )
        );
        mispinned.initialize(manifest);
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

    function test_uninitializedCoreRegistryDoesNotVerify() public {
        // An uninitialized registry has nothing pinned — it must never read as verified.
        CoreRegistry blankRegistry = new CoreRegistry();
        assertFalse(blankRegistry.verifyAll());
    }

    function test_revertWhen_upgradingRowMissingSource() public {
        // A row that upgrades must be a full edge: known source implementation.
        CoreRegistry.CoreRegistryManifest memory manifest = _coreManifest();
        manifest.contractRows[0].expectedOldImpl = address(0);

        CoreRegistry sourceless = new CoreRegistry();
        vm.expectRevert(ZeroAddress.selector);
        sourceless.initialize(manifest);
    }
}

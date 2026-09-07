// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {MockSelfDescribingFacet} from "contracts/dev-contracts/test/MockSelfDescribingFacet.sol";
import {ISelfDescribingFacet} from "contracts/state-transition/chain-interfaces/ISelfDescribingFacet.sol";

import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMTransition} from "contracts/upgrades/registry/objects/ICTMTransition.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {IL2DelegateCalldataComposer} from "contracts/upgrades/registry/objects/IL2DelegateCalldataComposer.sol";
import {FixedDelegateCalldataComposer} from "contracts/dev-contracts/FixedDelegateCalldataComposer.sol";
import {CTMUpgradeComposer} from "contracts/upgrades/registry/libraries/CTMUpgradeComposer.sol";
import {ReleaseFacetReader} from "contracts/upgrades/registry/libraries/ReleaseFacetReader.sol";
import {TransitionDerivationLib} from "contracts/upgrades/registry/libraries/TransitionDerivationLib.sol";
import {L2InventoryLib} from "contracts/upgrades/registry/libraries/L2InventoryLib.sol";
import {L2PlanFixtures} from "./L2PlanFixtures.sol";
import {L2GenesisForceDeploymentsHelper} from "contracts/l2-upgrades/L2GenesisForceDeploymentsHelper.sol";
import {L2_BRIDGEHUB_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
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
    L2BytecodeNotInFactoryDeps,
    L2DelegateNotAnExtraDeployment,
    L2ExtraDeploymentNotBytecodeDerived,
    L2ExtraDeploymentNotUnsafe,
    MalformedL2UpgradePlan,
    PatchMustReuseRelease,
    RegistryCodehashMismatch,
    RegistryDuplicateProxyRow,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    RegistryInventoryLengthMismatch,
    RegistryMemberHasNoFixedAddress,
    RegistryPinTargetHasNoCode,
    RegistryUnknownKey,
    SameReleaseTransitionHasPayload,
    TransitionDeadlineBeforeUpgrade,
    ZeroAddress
} from "contracts/common/L1ContractErrors.sol";
import {
    NewProtocolMajorVersionNotZero,
    ProtocolVersionMinorDeltaTooBig,
    ProtocolVersionTooSmall
} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {
    AuthoredL2Plan,
    CoreRegistryManifest,
    ProxyUpgradeRow,
    GenesisFacet,
    L2UpgradePlan,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest,
    PinnedContract
} from "../../../../../../../contracts/upgrades/registry/RegistryTypes.sol";
import {
    CTM_CONTRACT_COUNT,
    CTMContract,
    L1_ECOSYSTEM_CONTRACT_COUNT,
    L1EcosystemContract,
    L2_ECOSYSTEM_CONTRACT_COUNT,
    L2EcosystemContract
} from "../../../../../../../contracts/upgrades/registry/libraries/ContractIdentifiers.sol";

/// @notice Unit tests for the write-once upgrade objects in the DERIVED model: releases carry
///         explicit routing + inline mandatory pins; transitions derive their facet delta
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
    address internal upgradeTimer;
    address internal coreImplNew;
    /// @dev The pinned delegate-calldata composer of the default transition: a test-only stand-in
    ///      returning `DELEGATE_CALLDATA` regardless of its inputs, so this suite can pin a real
    ///      composer without a version-specific L2 migration behind it.
    FixedDelegateCalldataComposer internal delegateComposer;
    /// @dev The ecosystem Bridgehub the composer is handed. Only forwarded to the pinned composer
    ///      (which ignores it here), so a bare labelled address is all this suite needs.
    address internal bridgehub;

    uint256 internal constant OLD_VERSION = uint256(98) << 32;
    uint256 internal constant NEW_VERSION = uint256(99) << 32;
    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    // Dummy EVM bytecodes standing in for the L2 artifacts a hop installs (see {L2PlanFixtures}):
    // the authored extras (the upgrade delegate and one more Unsafe deployment) and the
    // system-proxied members a target release's table can carry.
    bytes internal constant DELEGATE_CODE = hex"aa01";
    bytes internal constant EXTRA_CODE = hex"aa02";
    bytes internal constant BRIDGEHUB_IMPL_CODE = hex"dd01";
    bytes internal constant SYSTEM_CONTEXT_IMPL_CODE = hex"dd02";
    bytes internal constant SYSTEM_PROXY_CODE = hex"dd00";

    function setUp() public {
        // Facets must actually self-describe their routing (the registry objects read it from
        // `ISelfDescribingFacet.selectors()`), so they are real mock deployments, not etches.
        facetOldAdmin = address(new MockSelfDescribingFacet(_selectors2(bytes4(uint32(1)), bytes4(uint32(2)))));
        facetNewAdmin = address(new MockSelfDescribingFacet(_selectors2(bytes4(uint32(2)), bytes4(uint32(3)))));
        facetShared = address(new MockSelfDescribingFacet(_selectors2(bytes4(uint32(0x10)), bytes4(uint32(0x11)))));
        facetFrozen = address(new MockSelfDescribingFacet(_selectors1(bytes4(uint32(0x20)))));
        genesisUpgrade = _pinned("genesisUpgrade");
        verifier = _pinned("verifier");
        upgradeEngine = _pinned("upgradeEngine");
        // The transition only pins the timer (the executor checks its binding), so a stand-in
        // with real code is all this suite needs.
        upgradeTimer = _pinned("upgradeTimer");
        coreImplNew = _pinned("coreImplNew");
        delegateComposer = new FixedDelegateCalldataComposer(DELEGATE_CALLDATA);
        bridgehub = makeAddr("bridgehub");
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

    function _coreManifest() internal view returns (CoreRegistryManifest memory manifest) {
        // One participating slot in the enum-indexed inventory — every other slot's zero
        // `implNew` is the explicit "not upgraded" statement and produces no row.
        manifest.proxyUpgrades = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)] = ProxyUpgradeRow({
            proxy: address(0xB001),
            expectedOldImpl: address(0xB101),
            implNew: PinnedContract({addr: coreImplNew, codehash: coreImplNew.codehash}),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
    }

    function _releaseManifest(address _adminFacet) internal view returns (ReleaseManifest memory manifest) {
        GenesisFacet[] memory facets = new GenesisFacet[](3);
        facets[0] = GenesisFacet({
            facet: PinnedContract({addr: _adminFacet, codehash: _adminFacet.codehash}),
            isFreezable: false
        });
        facets[1] = GenesisFacet({
            facet: PinnedContract({addr: facetShared, codehash: facetShared.codehash}),
            isFreezable: false
        });
        facets[2] = GenesisFacet({
            facet: PinnedContract({addr: facetFrozen, codehash: facetFrozen.codehash}),
            isFreezable: true
        });
        return
            ReleaseManifest({
                diamondInit: PinnedContract({addr: diamondInit, codehash: diamondInit.codehash}),
                verifier: PinnedContract({addr: verifier, codehash: verifier.codehash}),
                genesisUpgrade: PinnedContract({addr: genesisUpgrade, codehash: genesisUpgrade.codehash}),
                genesisFacets: facets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                // Length-checked inventory; content is irrelevant to this fixture.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT)
            });
    }

    function _fromReleaseManifest() internal view returns (ReleaseManifest memory) {
        return _releaseManifest(facetOldAdmin);
    }

    function _newReleaseManifest() internal view returns (ReleaseManifest memory) {
        // The hop replaces the admin facet (new address AND new selector set); the shared +
        // frozen facets carry over unchanged.
        return _releaseManifest(facetNewAdmin);
    }

    /// @dev The well-formed authored remainder: two Unsafe extras at their bytecode-derived
    ///      addresses, the delegate being the first of them, both bytecodes among the factory
    ///      dependencies, and the pinned composer defining the delegate's calldata.
    function _l2Plan() internal view returns (AuthoredL2Plan memory plan) {
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory extraDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](2);
        extraDeployments[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        extraDeployments[1] = L2PlanFixtures.unsafeDeployment(EXTRA_CODE);
        return
            AuthoredL2Plan({
                extraDeployments: extraDeployments,
                delegateTo: extraDeployments[0].newAddress,
                delegateComposer: _pin(address(delegateComposer)),
                factoryDepHashes: L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE, EXTRA_CODE))
            });
    }

    function _pin(address _addr) internal view returns (PinnedContract memory) {
        return PinnedContract({addr: _addr, codehash: _addr.codehash});
    }

    /// @dev The zero pin: no composer (the delegate is called with empty calldata), no ecosystem leg.
    function _noPin() internal pure returns (PinnedContract memory) {
        return PinnedContract({addr: address(0), codehash: bytes32(0)});
    }

    /// @dev The L2 transaction `_transition` composes against this suite's Bridgehub.
    function _l2Tx(CTMTransition _transition) internal view returns (L2CanonicalTransaction memory) {
        return CTMUpgradeComposer.buildL2UpgradeTx(ICTMTransition(address(_transition)), bridgehub);
    }

    /// @dev The factory dependencies a target release built by `_tableRelease()` installs: the
    ///      implementation AND the proxy shell of each of its two system-proxy rows.
    function _tableDeps() internal pure returns (uint256[] memory deps) {
        deps = new uint256[](4);
        deps[0] = L2PlanFixtures.factoryDepHash(BRIDGEHUB_IMPL_CODE);
        deps[1] = L2PlanFixtures.factoryDepHash(SYSTEM_PROXY_CODE);
        deps[2] = L2PlanFixtures.factoryDepHash(SYSTEM_CONTEXT_IMPL_CODE);
        deps[3] = L2PlanFixtures.factoryDepHash(SYSTEM_PROXY_CODE);
    }

    /// @dev `_l2Plan()` extended with the table dependencies, for hops toward `_tableRelease()`.
    function _l2PlanWithTableDeps() internal view returns (AuthoredL2Plan memory plan) {
        plan = _l2Plan();
        plan.factoryDepHashes = _concat(plan.factoryDepHashes, _tableDeps());
    }

    function _concat(uint256[] memory _a, uint256[] memory _b) internal pure returns (uint256[] memory joined) {
        joined = new uint256[](_a.length + _b.length);
        for (uint256 i = 0; i < _a.length; ++i) {
            joined[i] = _a[i];
        }
        for (uint256 i = 0; i < _b.length; ++i) {
            joined[_a.length + i] = _b[i];
        }
    }

    function _transitionManifest() internal view returns (TransitionManifest memory manifest) {
        // All CTM-domain inventory slots inert: this hop changes chain state, not the CTM itself.
        ProxyUpgradeRow[] memory noProxyUpgrades = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        return
            TransitionManifest({
                oldProtocolVersion: OLD_VERSION,
                newProtocolVersion: NEW_VERSION,
                fromRelease: address(fromRelease),
                newRelease: address(newRelease),
                upgradeEngine: PinnedContract({addr: upgradeEngine, codehash: upgradeEngine.codehash}),
                proxyUpgrades: noProxyUpgrades,
                oldProtocolVersionDeadline: type(uint256).max,
                upgradeTimestamp: 1234567,
                l2Plan: _l2Plan(),
                // No ecosystem leg by default; the timer is mandatory.
                coreRegistry: PinnedContract({addr: address(0), codehash: bytes32(0)}),
                upgradeTimer: PinnedContract({addr: upgradeTimer, codehash: upgradeTimer.codehash})
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

        // Derived, not authored — and stored as final cuts: a FULL REINSTALL, removals first.
        // One Remove cut per departing facet (facet address zero per Diamond semantics), one Add
        // cut per arriving facet; no selector-level diffing and no Replace bucket.
        Diamond.FacetCut[] memory derivedCuts = transition.facetCuts();
        assertEq(derivedCuts.length, 6);
        assertEq(derivedCuts[0].facet, address(0));
        assertTrue(derivedCuts[0].action == Diamond.Action.Remove);
        assertEq(derivedCuts[0].selectors.length, 2, "old admin routing removed");
        assertTrue(derivedCuts[1].action == Diamond.Action.Remove);
        assertTrue(derivedCuts[2].action == Diamond.Action.Remove);
        assertEq(derivedCuts[3].facet, facetNewAdmin);
        assertTrue(derivedCuts[3].action == Diamond.Action.Add);
        assertEq(derivedCuts[3].selectors.length, 2);
        assertFalse(derivedCuts[3].isFreezable);
        assertEq(derivedCuts[4].facet, facetShared);
        assertEq(derivedCuts[5].facet, facetFrozen);
        assertTrue(derivedCuts[5].isFreezable);
    }

    function test_composerBuildsL2TxAndProposalFromTransition() public {
        // The delegate calldata is DEFINED by the pinned composer, which the library asks with the
        // TARGET release and the Bridgehub it was handed — never with authored bytes.
        vm.expectCall(
            address(delegateComposer),
            abi.encodeCall(
                IL2DelegateCalldataComposer.composeDelegateCalldata,
                (ICTMRelease(address(newRelease)), bridgehub)
            )
        );
        L2CanonicalTransaction memory transaction = _l2Tx(transition);
        // VM identity single-source: the target release's DiamondInit was built with true.
        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE);
        assertEq(transaction.from, uint256(uint160(L2_FORCE_DEPLOYER_ADDR)));
        assertEq(transaction.to, uint256(uint160(L2_COMPLEX_UPGRADER_ADDR)));
        (, uint32 minor, ) = SemVer.unpackSemVer(uint96(NEW_VERSION));
        assertEq(transaction.nonce, minor);
        assertEq(transaction.factoryDeps.length, 2);
        L2UpgradePlan memory plan = transition.l2Plan();
        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (plan.deployments, plan.delegateTo, DELEGATE_CALLDATA)
            ),
            "the delegate is called with what the pinned composer composed"
        );

        ProposedUpgrade memory proposedUpgrade = CTMUpgradeComposer.buildProposedUpgrade(
            ICTMTransition(address(transition)),
            bridgehub
        );
        assertEq(
            keccak256(abi.encode(proposedUpgrade.l2ProtocolUpgradeTx)),
            keccak256(abi.encode(transaction)),
            "the proposal embeds the same composed transaction"
        );
        assertEq(proposedUpgrade.newProtocolVersion, NEW_VERSION);
        assertEq(proposedUpgrade.upgradeTimestamp, 1234567);
        assertEq(proposedUpgrade.verifier, verifier);
        // The frozen `ProposedUpgrade` still carries the EraVM bytecode-hash words; the composer
        // leaves them zero.
        assertEq(proposedUpgrade.bootloaderHash, bytes32(0));
        assertEq(proposedUpgrade.defaultAccountHash, bytes32(0));
        assertEq(proposedUpgrade.evmEmulatorHash, bytes32(0));
    }

    /// @dev Regression: the MINIMAL L2 plan — the delegate's own Unsafe deployment and nothing
    ///      else (the delegate must be one of the extras, so a plan can never be delegate-only)
    ///      — must still compose a transaction; previously such committed data was silently
    ///      discarded when no table-derived deployment rode along.
    function test_composerBuildsMinimalDelegatePlanL2Tx() public {
        TransitionManifest memory manifest = _transitionManifest();
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory delegateOnly = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        delegateOnly[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        manifest.l2Plan.extraDeployments = delegateOnly;
        manifest.l2Plan.factoryDepHashes = L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE));
        CTMTransition minimal = new CTMTransition(manifest);

        L2CanonicalTransaction memory transaction = _l2Tx(minimal);
        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE, "minimal delegate plan must compose a tx");
        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (delegateOnly, delegateOnly[0].newAddress, DELEGATE_CALLDATA)
            )
        );
        assertEq(transaction.factoryDeps.length, 1, "only the delegate's bytecode rides as a factory dep");
    }

    // ─────────────────────────── patches / same-release ───────────────────────────

    /// @dev A verifier/schedule-only SemVer patch: same release on both edges, +1 patch
    ///      version, and NO L2 payload — the only shape a same-release hop may take.
    function _patchManifest() internal view returns (TransitionManifest memory manifest) {
        manifest = _transitionManifest();
        manifest.oldProtocolVersion = NEW_VERSION;
        manifest.newProtocolVersion = NEW_VERSION + 1;
        manifest.fromRelease = address(newRelease);
        manifest.l2Plan = AuthoredL2Plan({
            extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
            delegateTo: address(0),
            delegateComposer: _noPin(),
            factoryDepHashes: new uint256[](0)
        });
    }

    function test_patchTransitionVerifierOnlyInitializes() public {
        CTMTransition patchTransition = new CTMTransition(_patchManifest());
        assertEq(patchTransition.fromRelease(), patchTransition.newRelease());
        // The derived delta of a same-release hop is empty by construction — the L2 force
        // deployments included, even though the release's table is only read cross-release.
        assertEq(patchTransition.facetCuts().length, 0);
        assertEq(patchTransition.l2Plan().deployments.length, 0, "same-release pair must derive no deployments");
        // Both edges are live releases, so runtime validation holds.
        patchTransition.validate();
        assertTrue(patchTransition.verifyAll());
    }

    function test_revertWhen_sameReleaseTransitionCarriesL2Payload() public {
        TransitionManifest memory manifest = _patchManifest();
        // A fully well-formed authored plan, so only the same-release rule can fire.
        manifest.l2Plan = _l2Plan();

        vm.expectRevert(SameReleaseTransitionHasPayload.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_sameReleaseTransitionCarriesAuthoredExtras() public {
        TransitionManifest memory manifest = _patchManifest();
        // The smallest payload a plan can carry: one Unsafe extra that is also the delegate, no
        // composer. Shape-valid, so only the same-release rule can fire.
        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory extras = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        extras[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        manifest.l2Plan.extraDeployments = extras;
        manifest.l2Plan.delegateTo = extras[0].newAddress;
        manifest.l2Plan.factoryDepHashes = L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE));

        vm.expectRevert(SameReleaseTransitionHasPayload.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_patchTargetsDifferentRelease() public {
        TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);

        vm.expectRevert(
            abi.encodeWithSelector(PatchMustReuseRelease.selector, address(fromRelease), address(newRelease))
        );
        new CTMTransition(manifest);
    }

    // ─────────────────────────── schedule / version guards ───────────────────────────

    function test_revertWhen_transitionVersionNotIncreasing() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newProtocolVersion = manifest.oldProtocolVersion;

        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector, OLD_VERSION, OLD_VERSION));
        new CTMTransition(manifest);
    }

    /// @dev The release does NOT own the routing concept: a split-row (same facet twice) release
    ///      constructs — routing well-formedness is enforced where routing executes. Here: the
    ///      transition deriving toward it rejects the duplicated selectors (`TransitionDerivationLib`),
    ///      BEFORE anything is committed. (Genesis would equally revert in `Diamond.diamondCut`.)
    function test_revertWhen_transitionDerivesTowardSplitRowRelease() public {
        ReleaseManifest memory manifest = _newReleaseManifest();
        // Same facet address in two rows: its selectors appear twice in the release's routing.
        manifest.genesisFacets[2].facet = PinnedContract({addr: facetShared, codehash: facetShared.codehash});
        CTMRelease splitRowRelease = new CTMRelease(manifest);

        TransitionManifest memory transitionManifest = _transitionManifest();
        transitionManifest.newRelease = address(splitRowRelease);

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateSelector.selector, bytes4(uint32(0x10))));
        new CTMTransition(transitionManifest);
    }

    /// @dev Regression: the transition must enforce the SAME version shape chains enforce at
    ///      execution (`BaseZkSyncUpgrade._setNewProtocolVersion`). Otherwise the transition pins,
    ///      stage 1 bumps the CTM, and every per-chain upgrade then reverts.
    function test_revertWhen_transitionUsesNonzeroMajorVersion() public {
        TransitionManifest memory manifest = _transitionManifest();
        // major = 1 — rejected per-chain, so it must be rejected at pin time too.
        manifest.newProtocolVersion = SemVer.packSemVer(1, 0, 0);

        vm.expectRevert(NewProtocolMajorVersionNotZero.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_transitionMinorDeltaTooBig() public {
        TransitionManifest memory manifest = _transitionManifest();
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
    ///      rejected at pin time. Otherwise stage 1 bumps the CTM version and every per-chain
    ///      upgrade then reverts, stranding chains on an unexecutable transition.
    function test_revertWhen_transitionExceedsFactoryDepCap() public {
        TransitionManifest memory manifest = _transitionManifest();
        // The extras' real hashes stay in front (so the presence rule holds); surplus dummies
        // push the list one past the cap.
        uint256[] memory tooManyDeps = new uint256[](MAX_NEW_FACTORY_DEPS + 1);
        uint256 realDeps = manifest.l2Plan.factoryDepHashes.length;
        for (uint256 i = 0; i < tooManyDeps.length; ++i) {
            tooManyDeps[i] = i < realDeps ? manifest.l2Plan.factoryDepHashes[i] : i + 1;
        }
        manifest.l2Plan.factoryDepHashes = tooManyDeps;

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_deadlineBeforeUpgradeTimestamp() public {
        // A deadline before the upgrade timestamp would disable the old protocol before chains
        // are even allowed to upgrade.
        TransitionManifest memory manifest = _transitionManifest();
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
        TransitionManifest memory manifest = _transitionManifest();
        manifest.fromRelease = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── lifecycle inputs (timer, ecosystem leg) ───────────────────────────

    function test_revertWhen_upgradeTimerZero() public {
        // Stage 1 is gated on the timer's deadline, so a transition without one cannot exist.
        TransitionManifest memory manifest = _transitionManifest();
        manifest.upgradeTimer = PinnedContract({addr: address(0), codehash: bytes32(0)});

        vm.expectRevert(ZeroAddress.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_transitionTimerPinMismatch() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.upgradeTimer.codehash = keccak256("not the timer's code");
        CTMTransition mispinned = new CTMTransition(manifest);
        assertEq(mispinned.upgradeTimer(), upgradeTimer, "the timer is served like every other pinned address");

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                upgradeTimer,
                keccak256("not the timer's code"),
                upgradeTimer.codehash
            )
        );
        mispinned.validate();
        assertFalse(mispinned.verifyAll(), "a mispinned timer must not verify");
    }

    /// @dev The ecosystem leg is optional: zero means "no leg" and is not pin-checked; a named
    ///      registry is pinned like every other address.
    function test_transitionCoreRegistryIsOptionalAndPinnedWhenNamed() public {
        assertEq(transition.coreRegistry(), address(0), "the default manifest names no ecosystem leg");
        transition.validate();
        assertTrue(transition.verifyAll());

        TransitionManifest memory manifest = _transitionManifest();
        manifest.coreRegistry = PinnedContract({addr: address(coreRegistry), codehash: address(coreRegistry).codehash});
        CTMTransition withLeg = new CTMTransition(manifest);
        assertEq(withLeg.coreRegistry(), address(coreRegistry));
        withLeg.validate();
        assertTrue(withLeg.verifyAll());

        manifest.coreRegistry.codehash = keccak256("not the registry's code");
        CTMTransition mispinned = new CTMTransition(manifest);
        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(coreRegistry),
                keccak256("not the registry's code"),
                address(coreRegistry).codehash
            )
        );
        mispinned.validate();
        assertFalse(mispinned.verifyAll(), "a mispinned ecosystem leg must not verify");
    }

    // ─────────────────────────── L2 plan shape ───────────────────────────

    function test_revertWhen_delegateComposerWithoutTarget() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.extraDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
        manifest.l2Plan.factoryDepHashes = new uint256[](0);
        manifest.l2Plan.delegateTo = address(0);
        // The composer pin stays — code defining calldata for a delegate call that never happens.

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_factoryDepsWithoutL2Side() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.extraDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
        manifest.l2Plan.delegateTo = address(0);
        manifest.l2Plan.delegateComposer = _noPin();
        // factoryDepHashes stay non-empty with no transaction to ride in.

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_deploymentsWithoutDelegateTarget() public {
        // Force-deployments but no delegate target: `L2ComplexUpgrader` always ends with the final
        // delegatecall, so a deployments-only plan would initialize here yet revert on L2 forever.
        // (The composer is cleared so ONLY the deployments-without-target rule can fire.)
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateTo = address(0);
        manifest.l2Plan.delegateComposer = _noPin();

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── delegate composer ───────────────────────────

    /// @dev The composer is version-specific CODE pinned in place of calldata, so it is held
    ///      against live code exactly like every other pin: a manifest whose pin disagrees with the
    ///      composer's code still constructs (pins are checked on the execution paths, see
    ///      {CTMRelease}) but fails `validate()` and does not verify.
    function test_revertWhen_transitionDelegateComposerPinMismatch() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateComposer.codehash = keccak256("not the composer's code");
        CTMTransition mispinned = new CTMTransition(manifest);
        assertEq(
            mispinned.l2Plan().delegateComposer,
            address(delegateComposer),
            "the composer is served like every other pinned address"
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(delegateComposer),
                keccak256("not the composer's code"),
                address(delegateComposer).codehash
            )
        );
        mispinned.validate();
        assertFalse(mispinned.verifyAll(), "a mispinned composer must not verify");
    }

    /// @dev The live side of the same pin: a correctly pinned composer whose code later differs
    ///      from the pin (modelled by re-etching it) stops the transition from validating.
    function test_revertWhen_delegateComposerCodeDrifts() public {
        transition.validate();
        assertTrue(transition.verifyAll());
        bytes32 pinned = address(delegateComposer).codehash;

        vm.etch(address(delegateComposer), hex"600042");

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                address(delegateComposer),
                pinned,
                address(delegateComposer).codehash
            )
        );
        transition.validate();
        assertFalse(transition.verifyAll(), "a drifted composer must not verify");
    }

    /// @dev A zero composer is a legal plan with a delegate target: the delegate is called with
    ///      EMPTY calldata, and there is no pin to hold.
    function test_zeroDelegateComposerComposesEmptyDelegateCalldata() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateComposer = _noPin();
        CTMTransition uncomposed = new CTMTransition(manifest);
        assertEq(uncomposed.l2Plan().delegateComposer, address(0), "no composer is served as zero");
        uncomposed.validate();
        assertTrue(uncomposed.verifyAll());

        L2CanonicalTransaction memory transaction = _l2Tx(uncomposed);
        L2UpgradePlan memory plan = uncomposed.l2Plan();
        assertEq(transaction.txType, ZKSYNC_OS_SYSTEM_UPGRADE_L2_TX_TYPE, "the plan still has an L2 side");
        assertEq(
            transaction.data,
            abi.encodeCall(IComplexUpgrader.forceDeployAndUpgradeUniversal, (plan.deployments, plan.delegateTo, "")),
            "without a composer the delegate is called with empty calldata"
        );
    }

    // ─────────────────────────── derived L2 deployments ───────────────────────────

    /// @dev A target release whose table carries canonical system-proxy rows at two fixed-address
    ///      members. Distinct bytecodes from the authored extras so the two sets are
    ///      distinguishable in the combined plan; their dependencies are `_tableDeps()`.
    function _tableRelease() internal returns (CTMRelease) {
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.l2BytecodeInfos[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.systemProxyRow(
            BRIDGEHUB_IMPL_CODE,
            SYSTEM_PROXY_CODE
        );
        manifest.l2BytecodeInfos[uint256(L2EcosystemContract.SystemContext)] = L2PlanFixtures.systemProxyRow(
            SYSTEM_CONTEXT_IMPL_CODE,
            SYSTEM_PROXY_CODE
        );
        return new CTMRelease(manifest);
    }

    function test_deriveL2DeploymentsFromTableSkipsEmptyRowsAndResolvesMembers() public {
        bytes[] memory table = new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
        table[uint256(L2EcosystemContract.L2Bridgehub)] = hex"dd01";
        table[uint256(L2EcosystemContract.SystemContext)] = hex"dd02";

        IComplexUpgrader.UniversalContractUpgradeInfo[] memory derived = TransitionDerivationLib
            .deriveL2DeploymentsFromTable(table, true);

        // Only the nonempty rows become deployments, in enum order, each at its member's
        // canonical fixed address.
        assertEq(derived.length, 2, "empty rows must derive no deployment");
        assertTrue(derived[0].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade);
        assertEq(derived[0].deployedBytecodeInfo, hex"dd01");
        assertEq(derived[0].newAddress, L2InventoryLib.fixedAddress(L2EcosystemContract.L2Bridgehub));
        assertEq(derived[1].deployedBytecodeInfo, hex"dd02");
        assertEq(derived[1].newAddress, L2InventoryLib.fixedAddress(L2EcosystemContract.SystemContext));

        // The Era flavour of the same table derives force deployments instead of proxy upgrades.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory derivedEra = TransitionDerivationLib
            .deriveL2DeploymentsFromTable(table, false);
        assertTrue(derivedEra[0].upgradeType == IComplexUpgrader.ContractUpgradeType.EraForceDeployment);
        assertEq(derivedEra.length, 2);
    }

    function test_revertWhen_transitionDerivesRowForAddresslessMember() public {
        // BeaconProxy is a bytecode-identity member: it has no fixed L2 address, so a table row
        // for it is unexecutable and must refuse to derive — at transition construction, before
        // anything is committed.
        ReleaseManifest memory releaseManifest = _newReleaseManifest();
        releaseManifest.l2BytecodeInfos[uint256(L2EcosystemContract.BeaconProxy)] = hex"dd03";
        CTMRelease rowRelease = new CTMRelease(releaseManifest);

        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(rowRelease);

        vm.expectRevert(
            abi.encodeWithSelector(RegistryMemberHasNoFixedAddress.selector, uint256(L2EcosystemContract.BeaconProxy))
        );
        new CTMTransition(manifest);
    }

    function test_transitionL2PlanIsDerivedPlusExtras() public {
        CTMRelease tableRelease = _tableRelease();
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(tableRelease);
        manifest.l2Plan = _l2PlanWithTableDeps();
        CTMTransition combined = new CTMTransition(manifest);

        // The FINAL plan: the target release's table-derived set first, the authored extras
        // appended after.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory expectedDerived = TransitionDerivationLib
            .deriveL2DeploymentsFromTable(tableRelease.l2BytecodeInfos(), true);
        L2UpgradePlan memory plan = combined.l2Plan();
        assertEq(
            plan.deployments.length,
            expectedDerived.length + manifest.l2Plan.extraDeployments.length,
            "final plan must be derived ++ extras"
        );
        for (uint256 i = 0; i < expectedDerived.length; ++i) {
            assertEq(abi.encode(plan.deployments[i]), abi.encode(expectedDerived[i]), "derived prefix mismatch");
        }
        for (uint256 i = 0; i < manifest.l2Plan.extraDeployments.length; ++i) {
            assertEq(
                abi.encode(plan.deployments[expectedDerived.length + i]),
                abi.encode(manifest.l2Plan.extraDeployments[i]),
                "authored extras suffix mismatch"
            );
        }
        // The authored remainder rides through unchanged.
        assertEq(plan.delegateTo, manifest.l2Plan.delegateTo);
        assertEq(plan.delegateComposer, address(delegateComposer), "the pinned composer is served");
        assertEq(plan.factoryDepHashes.length, manifest.l2Plan.factoryDepHashes.length);
        // ...and the composed transaction executes the COMBINED deployments, then the delegate
        // with the calldata the pinned composer defines.
        assertEq(
            _l2Tx(combined).data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (plan.deployments, plan.delegateTo, DELEGATE_CALLDATA)
            ),
            "composed data must be derived ++ extras, delegate, composer calldata"
        );
    }

    function test_revertWhen_derivedDeploymentsWithoutDelegateTarget() public {
        // The shape rules run against the COMBINED plan: a derived-nonempty transition with no
        // delegate target is unexecutable on L2 even when the manifest authors NO extras.
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(_tableRelease());
        manifest.l2Plan.extraDeployments = new IComplexUpgrader.UniversalContractUpgradeInfo[](0);
        manifest.l2Plan.delegateTo = address(0);
        manifest.l2Plan.delegateComposer = _noPin();
        // The derived rows' dependencies are all present, so only the shape rule can fire.
        manifest.l2Plan.factoryDepHashes = _tableDeps();

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── authored L2 remainder shape ───────────────────────────
    // What L1 CAN establish about the authored L2 side, mechanically (see L2PlanValidationLib):
    // extras are Unsafe at their bytecode-derived address, the delegate is one of them, and every
    // installed bytecode is a factory dependency. One test per rule, each on an otherwise
    // well-formed plan so exactly that rule fires.

    function test_wellFormedL2PlanPinsTheAuthoredRemainder() public view {
        L2UpgradePlan memory plan = transition.l2Plan();
        AuthoredL2Plan memory authored = _l2Plan();

        // No table rows on the target release: the final plan IS the authored extras.
        assertEq(plan.deployments.length, 2, "both extras must be pinned");
        for (uint256 i = 0; i < plan.deployments.length; ++i) {
            assertTrue(
                plan.deployments[i].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment
            );
            assertEq(
                plan.deployments[i].newAddress,
                L2GenesisForceDeploymentsHelper.generateRandomAddress(plan.deployments[i].deployedBytecodeInfo),
                "extra must sit at its bytecode-derived address"
            );
        }
        assertEq(plan.delegateTo, authored.extraDeployments[0].newAddress, "the delegate is the first extra");
        assertEq(plan.factoryDepHashes.length, 2);
        assertEq(plan.factoryDepHashes[0], L2PlanFixtures.factoryDepHash(DELEGATE_CODE));
        assertEq(plan.factoryDepHashes[1], L2PlanFixtures.factoryDepHash(EXTRA_CODE));
    }

    /// @dev An L1-only hop: no extras, no delegate, no factory deps. The zero delegate is the
    ///      one non-extra value the delegate rule admits.
    function test_l1OnlyTransitionWithoutL2PlanInitializes() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan = AuthoredL2Plan({
            extraDeployments: new IComplexUpgrader.UniversalContractUpgradeInfo[](0),
            delegateTo: address(0),
            delegateComposer: _noPin(),
            factoryDepHashes: new uint256[](0)
        });

        CTMTransition l1Only = new CTMTransition(manifest);

        L2UpgradePlan memory plan = l1Only.l2Plan();
        assertEq(plan.deployments.length, 0, "an L1-only hop deploys nothing on L2");
        assertEq(plan.delegateTo, address(0));
        assertEq(plan.delegateComposer, address(0));
        // No L2 side: the composer emits the all-zero transaction `BaseZkSyncUpgrade` skips.
        assertEq(_l2Tx(l1Only).txType, 0, "an L1-only hop composes no L2 transaction");
    }

    function test_revertWhen_extraDeploymentIsNotUnsafe() public {
        TransitionManifest memory manifest = _transitionManifest();
        // A system-proxy upgrade can only be table-derived; authored, it could re-point a fixed
        // built-in outside the release's own table.
        manifest.l2Plan.extraDeployments[1].upgradeType = IComplexUpgrader
            .ContractUpgradeType
            .ZKsyncOSSystemProxyUpgrade;

        vm.expectRevert(
            abi.encodeWithSelector(L2ExtraDeploymentNotUnsafe.selector, manifest.l2Plan.extraDeployments[1].newAddress)
        );
        new CTMTransition(manifest);
    }

    function test_revertWhen_extraDeploymentIsNotAtItsDerivedAddress() public {
        TransitionManifest memory manifest = _transitionManifest();
        // The right bytecode aimed at a fixed built-in's address instead of its derived one.
        address expected = manifest.l2Plan.extraDeployments[1].newAddress;
        manifest.l2Plan.extraDeployments[1].newAddress = L2_BRIDGEHUB_ADDR;

        vm.expectRevert(
            abi.encodeWithSelector(L2ExtraDeploymentNotBytecodeDerived.selector, expected, L2_BRIDGEHUB_ADDR)
        );
        new CTMTransition(manifest);
    }

    function test_revertWhen_extraDeploymentInfoHasWrongLength() public {
        TransitionManifest memory manifest = _transitionManifest();
        // Not a canonical (blake, length, keccak) tuple: the address derived from the junk info
        // is reported as the expected one, the authored address as the actual.
        bytes memory junkInfo = hex"aa02";
        address actual = manifest.l2Plan.extraDeployments[1].newAddress;
        manifest.l2Plan.extraDeployments[1].deployedBytecodeInfo = junkInfo;

        vm.expectRevert(
            abi.encodeWithSelector(
                L2ExtraDeploymentNotBytecodeDerived.selector,
                L2GenesisForceDeploymentsHelper.generateRandomAddress(junkInfo),
                actual
            )
        );
        new CTMTransition(manifest);
    }

    function test_revertWhen_delegateIsNotAnExtraDeployment() public {
        TransitionManifest memory manifest = _transitionManifest();
        // A nonzero delegate that none of the extras deploys: the delegatecall target would not
        // be pinned by any bytecode hash the manifest carries.
        address stranger = address(0x10004);
        manifest.l2Plan.delegateTo = stranger;

        vm.expectRevert(abi.encodeWithSelector(L2DelegateNotAnExtraDeployment.selector, stranger));
        new CTMTransition(manifest);
    }

    function test_revertWhen_extraBytecodeMissingFromFactoryDeps() public {
        TransitionManifest memory manifest = _transitionManifest();
        // Only the delegate's bytecode rides; the second extra's does not.
        manifest.l2Plan.factoryDepHashes = L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE));

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotInFactoryDeps.selector, keccak256(EXTRA_CODE)));
        new CTMTransition(manifest);
    }

    function test_revertWhen_derivedRowImplementationMissingFromFactoryDeps() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(_tableRelease());
        // `_l2Plan()` carries the extras' deps only: the first derived row's implementation
        // (L2Bridgehub, in enum order) is the first missing hash.

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotInFactoryDeps.selector, keccak256(BRIDGEHUB_IMPL_CODE)));
        new CTMTransition(manifest);
    }

    function test_revertWhen_derivedRowProxyMissingFromFactoryDeps() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(_tableRelease());
        // Every implementation is present but the shared proxy shell is not.
        uint256[] memory deps = new uint256[](4);
        deps[0] = L2PlanFixtures.factoryDepHash(DELEGATE_CODE);
        deps[1] = L2PlanFixtures.factoryDepHash(EXTRA_CODE);
        deps[2] = L2PlanFixtures.factoryDepHash(BRIDGEHUB_IMPL_CODE);
        deps[3] = L2PlanFixtures.factoryDepHash(SYSTEM_CONTEXT_IMPL_CODE);
        manifest.l2Plan.factoryDepHashes = deps;

        vm.expectRevert(abi.encodeWithSelector(L2BytecodeNotInFactoryDeps.selector, keccak256(SYSTEM_PROXY_CODE)));
        new CTMTransition(manifest);
    }

    // ─────────────────────────── routing hygiene ───────────────────────────

    function test_releaseDoesNotValidateRouting() public {
        // Deliberate non-check: a facet describing no selectors constructs fine — the release is
        // pinned data, and `Diamond.diamondCut` rejects empty routing (`NoFunctionsForDiamondCut`)
        // when a chain is actually created from it.
        address emptyFacet = address(new MockSelfDescribingFacet(new bytes4[](0)));
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].facet = PinnedContract({addr: emptyFacet, codehash: emptyFacet.codehash});

        CTMRelease release = new CTMRelease(manifest);
        assertEq(release.manifestHash(), keccak256(abi.encode(manifest)), "unvalidated routing still pins");
    }

    function test_revertWhen_releaseHasNoFacets() public {
        // A release IS a complete chain routing: an empty facet set describes an unusable chain
        // and would derive a remove-everything delta. Rejected at the release boundary.
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets = new GenesisFacet[](0);

        vm.expectRevert(abi.encodeWithSelector(RegistryEmptySelectors.selector, address(0)));
        CTMRelease empty = new CTMRelease(manifest);
    }

    function test_revertWhen_releasePinsCodelessFacet() public {
        // A codehash pin must be over ACTUAL code: an address with no code is not a real
        // implementation (its EXTCODEHASH is zero / the empty-code hash), so pinning it is refused
        // by `validate()`, which holds the pins against live code on every execution path. The
        // facet self-describes normally at construction; its code is stripped afterwards to model
        // a pinned target that no longer carries code at validation time.
        address codeless = address(new MockSelfDescribingFacet(_selectors1(bytes4(uint32(0x99)))));
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[0].facet = PinnedContract({addr: codeless, codehash: codeless.codehash});
        CTMRelease codelessRelease = new CTMRelease(manifest);
        vm.etch(codeless, "");

        vm.expectRevert(abi.encodeWithSelector(RegistryPinTargetHasNoCode.selector, codeless));
        codelessRelease.validate();
        assertFalse(codelessRelease.verifyAll(), "a codeless pin must not verify");
    }

    function test_revertWhen_transitionDerivesTowardSelectorCollision() public {
        // A selector routed twice constructs as a release (pinned data, no routing ownership) but
        // is rejected when a transition derives toward it — pre-commit, so a malformed routing
        // can never strand chains behind a bumped CTM version.
        // The colliding facet self-describes a selector facetFrozen also carries (0x20).
        address collidingFacet = address(new MockSelfDescribingFacet(_selectors1(bytes4(uint32(0x20)))));
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].facet = PinnedContract({addr: collidingFacet, codehash: collidingFacet.codehash});
        CTMRelease collidingRelease = new CTMRelease(manifest);

        TransitionManifest memory transitionManifest = _transitionManifest();
        transitionManifest.newRelease = address(collidingRelease);

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateSelector.selector, bytes4(uint32(0x20))));
        new CTMTransition(transitionManifest);
    }

    // ─────────────────────────── factory provenance ───────────────────────────

    function test_transitionDefersReleaseProvenanceToCtm() public {
        // Release PROVENANCE is deliberately NOT a transition concern: a permissionless manifest
        // could name any "factory", so the transition only validates each edge's routing/pins and
        // leaves attestation to the CTM's canonical `releaseFactory` (enforced when the release
        // becomes `currentRelease` — see the CTM-level provenance test). So a hand-deployed but
        // VALID release is accepted here and derives a normal delta.
        CTMRelease handDeployed = new CTMRelease(_newReleaseManifest());

        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(handDeployed);

        CTMTransition deferred = new CTMTransition(manifest);
        assertEq(deferred.newRelease(), address(handDeployed), "transition accepts a valid hand-deployed release");
    }

    // ─────────────────────────── pins ───────────────────────────

    function test_revertWhen_transitionPinMismatch() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.upgradeEngine.codehash = keccak256("not the engine's code");
        CTMTransition mispinned = new CTMTransition(manifest);

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                upgradeEngine,
                keccak256("not the engine's code"),
                upgradeEngine.codehash
            )
        );
        mispinned.validate();
        assertFalse(mispinned.verifyAll(), "a mispinned engine must not verify");
    }

    /// @dev The verifier pin moved to the release along with the verifier itself.
    function test_revertWhen_releaseVerifierPinMismatch() public {
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.verifier.codehash = keccak256("not the verifier's code");
        CTMRelease mispinned = new CTMRelease(manifest);

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryCodehashMismatch.selector,
                verifier,
                keccak256("not the verifier's code"),
                verifier.codehash
            )
        );
        mispinned.validate();
        assertFalse(mispinned.verifyAll(), "a mispinned verifier must not verify");
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

    // ─────────────────────────── core registry inventory ───────────────────────────

    function test_revertWhen_inventoryLengthDoesNotMatchTheEnum() public {
        // The dynamic inventory must be COMPLETE: exactly one slot per enum member, so a
        // manifest can neither omit a slot nor smuggle an extra one.
        CoreRegistryManifest memory manifest = _coreManifest();
        ProxyUpgradeRow[] memory tooShort = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT - 1);
        tooShort[uint256(L1EcosystemContract.L1Bridgehub)] = manifest.proxyUpgrades[
            uint256(L1EcosystemContract.L1Bridgehub)
        ];
        manifest.proxyUpgrades = tooShort;

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryInventoryLengthMismatch.selector,
                L1_ECOSYSTEM_CONTRACT_COUNT,
                L1_ECOSYSTEM_CONTRACT_COUNT - 1
            )
        );
        new CoreRegistry(manifest);
    }

    function test_revertWhen_upgradingRowMissingSource() public {
        // A participating slot must be a full edge: known source implementation.
        CoreRegistryManifest memory manifest = _coreManifest();
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)].expectedOldImpl = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new CoreRegistry(manifest);
    }

    function test_inertSlotIsExplicitNotUpgradedAndProducesNoRow() public {
        // A slot with zero `implNew` is the inventory's explicit "not upgraded" statement:
        // it never becomes a row, even when it documents the proxy address it refers to.
        CoreRegistryManifest memory manifest = _coreManifest();
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1MessageRoot)].proxy = address(0xB002);

        CoreRegistry registry = new CoreRegistry(manifest);
        assertEq(registry.ecosystemRows().length, 1, "the inert slot must be dropped at the flatten boundary");
        assertEq(registry.ecosystemRows()[0].proxy, address(0xB001), "the participating slot must survive");
    }

    function test_revertWhen_everyInventorySlotIsInert() public {
        // A registry whose whole inventory is "not upgraded" upgrades nothing — refused.
        CoreRegistryManifest memory manifest = _coreManifest();
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)].implNew = PinnedContract({
            addr: address(0),
            codehash: bytes32(0)
        });

        vm.expectRevert(RegistryUnknownKey.selector);
        new CoreRegistry(manifest);
    }

    function test_revertWhen_coreRegistryHasDuplicateProxyRow() public {
        // A proxy is routed once: two slots naming the same proxy are rejected.
        CoreRegistryManifest memory manifest = _coreManifest();
        // same proxy again, in another contract's slot
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1MessageRoot)] = manifest.proxyUpgrades[
            uint256(L1EcosystemContract.L1Bridgehub)
        ];

        vm.expectRevert(
            abi.encodeWithSelector(
                RegistryDuplicateProxyRow.selector,
                manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)].proxy
            )
        );
        new CoreRegistry(manifest);
    }

    // ─────────────────────────── CTM-domain inventory ───────────────────────────

    /// @dev The enum is append-only and the inventory length is derived from it: the notifier
    ///      slot must be the LAST member, and the count must have grown with it.
    function test_ctmInventoryEndsWithTheServerNotifierSlot() public pure {
        assertEq(
            uint256(CTMContract.ServerNotifier),
            uint256(type(CTMContract).max),
            "ServerNotifier must be the last member"
        );
        assertEq(
            CTM_CONTRACT_COUNT,
            uint256(CTMContract.ServerNotifier) + 1,
            "the inventory length must cover the notifier slot"
        );
    }

    /// @dev A row's `admin` rides the manifest into the flattened rows unchanged: zero for rows
    ///      under the applying executor's bound admin, the named admin otherwise — and it is part
    ///      of the committed manifest hash.
    function test_transitionRowsCarryTheirNamedAdmin() public {
        address ctmImplNew = _pinned("ctmImplNew");
        address notifierImplNew = _pinned("notifierImplNew");
        ProxyAdmin notifierAdmin = ProxyAdmin(makeAddr("notifierAdmin"));
        TransitionManifest memory manifest = _transitionManifest();
        manifest.proxyUpgrades[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: address(0xC001),
            expectedOldImpl: address(0xC101),
            implNew: PinnedContract({addr: ctmImplNew, codehash: ctmImplNew.codehash}),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        manifest.proxyUpgrades[uint256(CTMContract.ServerNotifier)] = ProxyUpgradeRow({
            proxy: address(0xC002),
            expectedOldImpl: address(0xC102),
            implNew: PinnedContract({addr: notifierImplNew, codehash: notifierImplNew.codehash}),
            callInitializeUpgrade: false,
            admin: notifierAdmin
        });

        CTMTransition withRows = new CTMTransition(manifest);
        ProxyUpgradeRow[] memory rows = withRows.ctmProxyRows();
        assertEq(rows.length, 2, "both participating slots become rows, in inventory order");
        assertEq(rows[0].proxy, address(0xC001));
        assertEq(address(rows[0].admin), address(0), "a bound-admin row names no admin");
        assertEq(rows[1].proxy, address(0xC002));
        assertEq(address(rows[1].admin), address(notifierAdmin), "the notifier row names its own admin");
        assertEq(withRows.manifestHash(), keccak256(abi.encode(manifest)), "the admin is part of the commitment");
    }
}

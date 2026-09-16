// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";
import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {CoreRegistry} from "contracts/upgrades/registry/objects/CoreRegistry.sol";
import {EcosystemUpgradeOperation} from "contracts/upgrades/registry/objects/EcosystemUpgradeOperation.sol";
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
    PatchCannotCarryL2Upgrade,
    PatchChangesL2GenesisState,
    RegistryDuplicateFacetRow,
    RegistryDuplicateProxyRow,
    RegistryDuplicateSelector,
    RegistryEmptySelectors,
    RegistryInventoryLengthMismatch,
    RegistryMemberHasNoFixedAddress,
    RegistryTargetHasNoCode,
    OperationChangesNothing,
    RegistryUnknownKey,
    SameReleaseTransitionHasPayload,
    TransitionDeadlineBeforeUpgrade,
    TransitionDeadlineZero,
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
    OperationManifest,
    ProxyUpgradeRow,
    GenesisFacet,
    L2UpgradePlan,
    ReleaseGenesisData,
    ReleaseManifest,
    TransitionManifest
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

    // Pinned synthetic contracts (etched with distinct bytecode so each is a real deployed member).
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
    /// @dev The chain the L2 transaction is composed for; forwarded to the pinned composer like
    ///      the Bridgehub.
    uint256 internal constant CHAIN_ID = 271;
    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    // Dummy EVM bytecodes standing in for the L2 artifacts a hop installs (see {L2PlanFixtures}):
    // the authored extras (the upgrade delegate and one more Unsafe deployment) and the
    // system-proxied members a target release's table can carry.
    bytes internal constant DELEGATE_CODE = hex"aa01";
    bytes internal constant EXTRA_CODE = hex"aa02";
    bytes internal constant BRIDGEHUB_IMPL_CODE = hex"dd01";
    bytes internal constant SYSTEM_CONTEXT_IMPL_CODE = hex"dd02";
    bytes internal constant SYSTEM_PROXY_CODE = hex"dd00";
    // Distinct stand-ins for the release-pair L2 diff tests: a changed SystemContext
    // implementation and a member new to the set.
    bytes internal constant CHANGED_SYSTEM_CONTEXT_IMPL_CODE = hex"dd12";
    bytes internal constant ASSET_ROUTER_IMPL_CODE = hex"dd13";
    bytes internal constant CHANGED_SYSTEM_PROXY_CODE = hex"dd10";

    function setUp() public {
        // Facets must actually self-describe their routing (the registry objects read it from
        // `ISelfDescribingFacet.selectors()`), so they are real mock deployments, not etches.
        facetOldAdmin = address(new MockSelfDescribingFacet(_selectors2(bytes4(uint32(1)), bytes4(uint32(2)))));
        facetNewAdmin = address(new MockSelfDescribingFacet(_selectors2(bytes4(uint32(2)), bytes4(uint32(3)))));
        facetShared = address(new MockSelfDescribingFacet(_selectors2(bytes4(uint32(0x10)), bytes4(uint32(0x11)))));
        facetFrozen = address(new MockSelfDescribingFacet(_selectors1(bytes4(uint32(0x20)))));
        genesisUpgrade = _deployedStub("genesisUpgrade");
        verifier = _deployedStub("verifier");
        upgradeEngine = _deployedStub("upgradeEngine");
        // The transition only pins the timer (the executor checks its binding), so a stand-in
        // with real code is all this suite needs.
        upgradeTimer = _deployedStub("upgradeTimer");
        coreImplNew = _deployedStub("coreImplNew");
        delegateComposer = new FixedDelegateCalldataComposer(DELEGATE_CALLDATA);
        bridgehub = makeAddr("bridgehub");
        // A real DiamondInit, the one every fixture release pins.
        diamondInit = address(new DiamondInit());

        coreRegistry = new CoreRegistry(_coreManifest());
        // Releases deploy through the canonical factory: transition initialization enforces
        // factory provenance on BOTH edges.
        fromRelease = new CTMRelease(_fromReleaseManifest());
        newRelease = new CTMRelease(_newReleaseManifest());
        transition = new CTMTransition(_transitionManifest());
    }

    /// @dev Deploys a distinct-bytecode stand-in at a labelled address so EXTCODEHASH pins are
    ///      real (an empty address would pin the zero hash).
    function _deployedStub(string memory _name) internal returns (address addr) {
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
            implNew: coreImplNew,
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
    }

    function _releaseManifest(address _adminFacet) internal view returns (ReleaseManifest memory manifest) {
        GenesisFacet[] memory facets = new GenesisFacet[](3);
        facets[0] = GenesisFacet({facet: _adminFacet, isFreezable: false});
        facets[1] = GenesisFacet({facet: facetShared, isFreezable: false});
        facets[2] = GenesisFacet({facet: facetFrozen, isFreezable: true});
        return
            ReleaseManifest({
                diamondInit: diamondInit,
                verifier: verifier,
                genesisUpgrade: genesisUpgrade,
                genesisFacets: facets,
                genesis: ReleaseGenesisData({
                    fixedForceDeploymentsData: hex"f1f2",
                    genesisBatchHash: bytes32(uint256(1)),
                    genesisBatchCommitment: bytes32(uint256(1)),
                    genesisIndexRepeatedStorageChanges: 54
                }),
                // Length-checked inventory; content is irrelevant to this fixture. The shell is
                // the one `_tableRelease()` rows sit behind.
                l2BytecodeInfos: new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT),
                l2SystemProxyBytecodeInfo: L2PlanFixtures.bytecodeInfo(SYSTEM_PROXY_CODE)
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

    /// @dev The authored L2 input with everything a version can author: the delegate's bytecode
    ///      info, one extra bytecode info, and the pinned composer defining the delegate's
    ///      calldata. The object constructs both Unsafe deployments, the delegate target and the
    ///      factory dependencies from it.
    function _l2Plan() internal view returns (AuthoredL2Plan memory plan) {
        return L2PlanFixtures.delegatePlanWithExtra(DELEGATE_CODE, EXTRA_CODE, address(delegateComposer));
    }

    /// @dev The deployments the object constructs for `_l2Plan()`: the delegate first, the extra after.
    function _authoredDeployments()
        internal
        pure
        returns (IComplexUpgrader.UniversalContractUpgradeInfo[] memory list)
    {
        list = new IComplexUpgrader.UniversalContractUpgradeInfo[](2);
        list[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
        list[1] = L2PlanFixtures.unsafeDeployment(EXTRA_CODE);
    }

    /// @dev The zero pin: no composer (the delegate is called with empty calldata), no ecosystem leg.
    /// @dev The L2 transaction `_transition` composes against this suite's Bridgehub and chain.
    function _l2Tx(CTMTransition _transition) internal view returns (L2CanonicalTransaction memory) {
        return CTMUpgradeComposer.buildL2UpgradeTx(ICTMTransition(address(_transition)), bridgehub, CHAIN_ID);
    }

    /// @dev The factory dependencies a hop toward `_tableRelease()` with `_l2Plan()` constructs:
    ///      the table rows' bytecodes in member order (the shared proxy shell once), then the
    ///      authored delegate's and extra's.
    function _tableHopDeps() internal pure returns (uint256[] memory) {
        return
            L2PlanFixtures.factoryDepHashes(
                L2PlanFixtures.codes(
                    BRIDGEHUB_IMPL_CODE,
                    SYSTEM_PROXY_CODE,
                    SYSTEM_CONTEXT_IMPL_CODE,
                    DELEGATE_CODE,
                    EXTRA_CODE
                )
            );
    }

    function _transitionManifest() internal view returns (TransitionManifest memory manifest) {
        return
            TransitionManifest({
                oldProtocolVersion: OLD_VERSION,
                newProtocolVersion: NEW_VERSION,
                fromRelease: address(fromRelease),
                newRelease: address(newRelease),
                upgradeEngine: upgradeEngine,
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
        // TARGET release, the Bridgehub and the chain it was handed — never with authored bytes.
        vm.expectCall(
            address(delegateComposer),
            abi.encodeCall(
                IL2DelegateCalldataComposer.composeDelegateCalldata,
                (ICTMRelease(address(newRelease)), bridgehub, CHAIN_ID)
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
    }

    /// @dev Regression: the MINIMAL L2 plan — the delegate alone (its own Unsafe deployment is
    ///      constructed, so a plan can never be delegate-only) — must still compose a transaction;
    ///      previously such committed data was silently discarded when no table-derived
    ///      deployment rode along.
    function test_composerBuildsMinimalDelegatePlanL2Tx() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.extraBytecodeInfos = new bytes[](0);
        CTMTransition minimal = new CTMTransition(manifest);

        IComplexUpgrader.UniversalContractUpgradeInfo[]
            memory delegateOnly = new IComplexUpgrader.UniversalContractUpgradeInfo[](1);
        delegateOnly[0] = L2PlanFixtures.unsafeDeployment(DELEGATE_CODE);
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
        manifest.l2Plan = L2PlanFixtures.emptyPlan();
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
    }

    function test_revertWhen_sameReleaseTransitionCarriesL2Payload() public {
        TransitionManifest memory manifest = _patchManifest();
        // A fully well-formed authored plan, so only the same-release rule can fire.
        manifest.l2Plan = _l2Plan();

        vm.expectRevert(SameReleaseTransitionHasPayload.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_sameReleaseTransitionCarriesAnUncomposedDelegate() public {
        TransitionManifest memory manifest = _patchManifest();
        // The smallest payload a plan can carry: the delegate alone, no composer. Shape-valid, so
        // only the same-release rule can fire.
        manifest.l2Plan = L2PlanFixtures.delegatePlan(DELEGATE_CODE, address(0));

        vm.expectRevert(SameReleaseTransitionHasPayload.selector);
        new CTMTransition(manifest);
    }

    /// @dev A PATCH may name a new release: the release is the snapshot of the intended
    ///      contracts, and replacing an L1 member of it changes no chain-visible L2 state. Here
    ///      the target release replaces the admin facet, so the patch even derives real cuts.
    function test_patchMayTargetANewRelease() public {
        TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);

        CTMTransition patch = new CTMTransition(manifest);

        assertEq(patch.fromRelease(), address(fromRelease));
        assertEq(patch.newRelease(), address(newRelease));
        assertTrue(patch.facetCuts().length != 0, "the target release replaces a facet, so cuts are derived");
        assertEq(patch.l2Plan().deployments.length, 0, "an unchanged L2 table derives no L2 deployment");
    }

    /// @dev What a patch may NOT do: carry an L2 upgrade transaction.
    ///      `BaseZkSyncUpgrade._setL2SystemContractUpgrade` refuses one on a patch edge, and a
    ///      patch deliberately skips the "previous L2 upgrade finalized" check — so an L2 payload
    ///      on a patch would commit fine, bump the CTM, and then revert on every chain.
    function test_revertWhen_patchCarriesAnAuthoredL2Payload() public {
        TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);
        manifest.l2Plan = _l2Plan();

        vm.expectRevert(PatchCannotCarryL2Upgrade.selector);
        new CTMTransition(manifest);
    }

    /// @dev The DERIVED half of the same rule: a patch whose target release changes the L2
    ///      bytecode table derives force deployments, which is an L2 upgrade by another name. The
    ///      plan here is otherwise well-formed (delegate and composer), so the patch rule is what
    ///      rejects it.
    function test_revertWhen_patchDerivesL2DeploymentsFromItsTargetRelease() public {
        TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);
        manifest.newRelease = address(_tableRelease());
        manifest.l2Plan = _l2Plan();

        vm.expectRevert(PatchCannotCarryL2Upgrade.selector);
        new CTMTransition(manifest);
    }

    /// @dev The genesis half of the same rule: a patch whose target release describes a different
    ///      L2 genesis is never executed on existing chains, so chains created after the patch
    ///      would start from a state the patched chains never reached. An empty DERIVED deployment
    ///      list does not cover this — only the tables agree there.
    function test_revertWhen_patchTargetsAReleaseWithDifferentGenesisState() public {
        ReleaseManifest memory releaseManifest = _newReleaseManifest();
        releaseManifest.genesis.fixedForceDeploymentsData = hex"f1f3";
        CTMRelease genesisRelease = new CTMRelease(releaseManifest);

        TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);
        manifest.newRelease = address(genesisRelease);

        vm.expectRevert(PatchChangesL2GenesisState.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_patchTargetsAReleaseWithADifferentGenesisBatch() public {
        ReleaseManifest memory releaseManifest = _newReleaseManifest();
        releaseManifest.genesis.genesisBatchHash = bytes32(uint256(2));
        CTMRelease genesisRelease = new CTMRelease(releaseManifest);

        TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);
        manifest.newRelease = address(genesisRelease);

        vm.expectRevert(PatchChangesL2GenesisState.selector);
        new CTMTransition(manifest);
    }

    /// @dev The shell is part of the release's L2 description like the table it belongs to: a
    ///      patch derives no L2 deployment, so a changed shell would reach no existing chain.
    function test_revertWhen_patchTargetsAReleaseWithADifferentSystemProxyShell() public {
        ReleaseManifest memory releaseManifest = _newReleaseManifest();
        releaseManifest.l2SystemProxyBytecodeInfo = L2PlanFixtures.bytecodeInfo(CHANGED_SYSTEM_PROXY_CODE);
        CTMRelease shellRelease = new CTMRelease(releaseManifest);

        TransitionManifest memory manifest = _patchManifest();
        manifest.fromRelease = address(fromRelease);
        manifest.newRelease = address(shellRelease);

        vm.expectRevert(PatchChangesL2GenesisState.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── schedule / version guards ───────────────────────────

    function test_revertWhen_transitionVersionNotIncreasing() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newProtocolVersion = manifest.oldProtocolVersion;

        vm.expectRevert(abi.encodeWithSelector(ProtocolVersionTooSmall.selector, OLD_VERSION, OLD_VERSION));
        new CTMTransition(manifest);
    }

    /// @dev A split-row release (the same facet address in two rows) is now refused by the release
    ///      itself, at construction — so no transition can ever be derived toward one. Retargeted
    ///      from the derivation-time `RegistryDuplicateSelector` this used to trip: the check moved
    ///      earlier, it did not go away. `ReleaseFacetRows.t.sol` carries the rest of it (the same
    ///      refusal from `validate()`, on an object whose constructor never ran the check); the
    ///      derivation-time selector check is still exercised by the collision test below, which
    ///      uses a DISTINCT facet carrying an already-routed selector.
    function test_revertWhen_releaseSplitsOneFacetAcrossTwoRows() public {
        ReleaseManifest memory manifest = _newReleaseManifest();
        // Same facet address in two rows: its selectors would appear twice in the routing.
        manifest.genesisFacets[2].facet = facetShared;

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateFacetRow.selector, facetShared));
        new CTMRelease(manifest);
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

    /// @dev Regression: a plan whose CONSTRUCTED factory dependencies exceed what
    ///      `BaseZkSyncUpgrade` accepts must be rejected at pin time. Otherwise stage 1 bumps the
    ///      CTM version and every per-chain upgrade then reverts, stranding chains on an
    ///      unexecutable transition. The delegate plus `MAX_NEW_FACTORY_DEPS` distinct extras is
    ///      one dependency past the cap; one extra fewer constructs.
    function test_revertWhen_transitionExceedsFactoryDepCap() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.extraBytecodeInfos = _distinctExtraInfos(MAX_NEW_FACTORY_DEPS);

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);

        manifest.l2Plan.extraBytecodeInfos = _distinctExtraInfos(MAX_NEW_FACTORY_DEPS - 1);
        CTMTransition atCap = new CTMTransition(manifest);
        assertEq(atCap.l2Plan().factoryDepHashes.length, MAX_NEW_FACTORY_DEPS, "exactly the cap constructs");
    }

    /// @dev `_count` bytecode infos of pairwise-distinct dummy codes.
    function _distinctExtraInfos(uint256 _count) internal pure returns (bytes[] memory infos) {
        infos = new bytes[](_count);
        for (uint256 i = 0; i < _count; ++i) {
            infos[i] = L2PlanFixtures.bytecodeInfo(abi.encodePacked(bytes2(0xee00), uint8(i)));
        }
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

    function test_revertWhen_deadlineZero() public {
        // A zeroed deadline satisfies the relative check (`0 >= 0`) but expires the departing
        // version the instant the edge is committed, halting batch commitment for every chain
        // still on it — before any of them has had the chance to upgrade.
        TransitionManifest memory manifest = _transitionManifest();
        manifest.upgradeTimestamp = 0;
        manifest.oldProtocolVersionDeadline = 0;

        vm.expectRevert(TransitionDeadlineZero.selector);
        new CTMTransition(manifest);
    }

    function test_upgradeTimestampZeroStaysValid() public {
        // Zero is a legitimate `upgradeTimestamp`: it means chains may upgrade as soon as the
        // edge is committed. Only the deadline carries a lower bound.
        TransitionManifest memory manifest = _transitionManifest();
        manifest.upgradeTimestamp = 0;

        CTMTransition transition = new CTMTransition(manifest);

        assertEq(transition.upgradeTimestamp(), 0, "upgradeTimestamp");
        assertEq(
            transition.oldProtocolVersionDeadline(),
            manifest.oldProtocolVersionDeadline,
            "oldProtocolVersionDeadline"
        );
    }

    function test_revertWhen_fromReleaseZero() public {
        // Pre-registry migration is one-time migration code in the legacy scripts, not a
        // permanent zero-source special case.
        TransitionManifest memory manifest = _transitionManifest();
        manifest.fromRelease = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── operation shape ───────────────────────────

    function test_revertWhen_operationTimerZero() public {
        // Stage 1 is gated on the timer's deadline, so an operation without one cannot exist.
        OperationManifest memory manifest = _operationManifest();
        manifest.timer = address(0);

        vm.expectRevert(ZeroAddress.selector);
        new EcosystemUpgradeOperation(manifest);
    }

    function test_revertWhen_operationTimerHasNoCode() public {
        // Stage 1 calls `checkDeadline()` on the timer, and a call to a codeless address returning
        // nothing would SUCCEED silently — so the operation's check surface refuses it.
        EcosystemUpgradeOperation committed = new EcosystemUpgradeOperation(_operationManifest());
        assertEq(committed.timer(), upgradeTimer, "the timer is served like every other member");

        vm.etch(upgradeTimer, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, upgradeTimer));
        committed.validate();
    }

    /// @dev An operation that changes nothing is a mistake, not an upgrade — and the mere presence
    ///      of an all-inert inventory must not make it look like one that changes something.
    function test_revertWhen_operationChangesNothing() public {
        OperationManifest memory manifest = _operationManifest();
        manifest.transition = address(0);

        vm.expectRevert(OperationChangesNothing.selector);
        new EcosystemUpgradeOperation(manifest);
    }

    /// @dev Each change on its own is a complete operation.
    function test_operationWithOnlyACoreChange() public {
        OperationManifest memory manifest = _operationManifest();
        manifest.transition = address(0);
        manifest.coreRegistry = address(coreRegistry);

        EcosystemUpgradeOperation operation = new EcosystemUpgradeOperation(manifest);
        assertEq(operation.coreRegistry(), address(coreRegistry));
        assertEq(operation.transition(), address(0));
        assertEq(operation.ctmInfrastructureRows().length, 0, "no infrastructure row");
        assertEq(operation.manifestHash(), keccak256(abi.encode(manifest)));
    }

    function test_operationWithOnlyInfrastructure() public {
        OperationManifest memory manifest = _operationManifest();
        manifest.transition = address(0);
        manifest.ctmInfrastructure = _ctmInventoryWithTwoRows();

        EcosystemUpgradeOperation operation = new EcosystemUpgradeOperation(manifest);
        assertEq(operation.coreRegistry(), address(0));
        assertEq(operation.transition(), address(0), "no chain-version edge is bought for an infrastructure change");
        assertEq(operation.ctmInfrastructureRows().length, 2, "both participating slots become rows");
        operation.validate();
    }

    function test_operationWithOnlyATransition() public {
        EcosystemUpgradeOperation operation = new EcosystemUpgradeOperation(_operationManifest());
        assertEq(operation.coreRegistry(), address(0));
        assertEq(operation.transition(), address(transition));
        assertEq(operation.ctmInfrastructureRows().length, 0, "no infrastructure row");
    }

    function test_revertWhen_operationInventoryLengthMismatch() public {
        OperationManifest memory manifest = _operationManifest();
        manifest.ctmInfrastructure = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT - 1);

        vm.expectRevert(
            abi.encodeWithSelector(RegistryInventoryLengthMismatch.selector, CTM_CONTRACT_COUNT, CTM_CONTRACT_COUNT - 1)
        );
        new EcosystemUpgradeOperation(manifest);
    }

    // ─────────────────────────── L2 plan shape ───────────────────────────

    function test_revertWhen_delegateComposerWithoutDelegate() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateBytecodeInfo = "";
        manifest.l2Plan.extraBytecodeInfos = new bytes[](0);
        // The composer stays — code defining calldata for a delegate call that never happens.

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_extrasWithoutDelegate() public {
        // Force-deployments but no delegate: `L2ComplexUpgrader` always ends with the final
        // delegatecall, so a deployments-only plan would initialize here yet revert on L2 forever.
        // (The composer is cleared so ONLY the deployments-without-delegate rule can fire.)
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateBytecodeInfo = "";
        manifest.l2Plan.delegateComposer = address(0);

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── delegate composer ───────────────────────────

    /// @dev The composer is version-specific CODE in place of authored calldata, so the plan is
    ///      unexecutable if nothing is deployed at the address the manifest names — held on the
    ///      execution paths by `validate()`, not at construction (see {CTMRelease}).
    function test_revertWhen_transitionDelegateComposerHasNoCode() public {
        TransitionManifest memory manifest = _transitionManifest();
        CTMTransition committed = new CTMTransition(manifest);
        assertEq(
            committed.l2Plan().delegateComposer,
            address(delegateComposer),
            "the composer is served like every other member"
        );

        vm.etch(address(delegateComposer), "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, address(delegateComposer)));
        committed.validate();
    }

    /// @dev A zero composer is a legal plan with a delegate target: the delegate is called with
    ///      EMPTY calldata, and there is no composer to require code at.
    function test_zeroDelegateComposerComposesEmptyDelegateCalldata() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.delegateComposer = address(0);
        CTMTransition uncomposed = new CTMTransition(manifest);
        assertEq(uncomposed.l2Plan().delegateComposer, address(0), "no composer is served as zero");
        uncomposed.validate();

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

    /// @dev A target release whose table carries implementation rows at two fixed-address members
    ///      (behind the fixture's shared shell). Distinct bytecodes from the authored extras so
    ///      the two sets are distinguishable in the combined plan; their dependencies are
    ///      `_tableDeps()`.
    function _tableRelease() internal returns (CTMRelease) {
        return new CTMRelease(_tableReleaseManifest());
    }

    function _tableReleaseManifest() internal view returns (ReleaseManifest memory manifest) {
        manifest = _newReleaseManifest();
        manifest.l2BytecodeInfos[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.bytecodeInfo(
            BRIDGEHUB_IMPL_CODE
        );
        manifest.l2BytecodeInfos[uint256(L2EcosystemContract.SystemContext)] = L2PlanFixtures.bytecodeInfo(
            SYSTEM_CONTEXT_IMPL_CODE
        );
    }

    function test_deriveL2DeploymentsFromTableSkipsEmptyRowsAndResolvesMembers() public {
        bytes[] memory table = new bytes[](L2_ECOSYSTEM_CONTRACT_COUNT);
        table[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.bytecodeInfo(BRIDGEHUB_IMPL_CODE);
        table[uint256(L2EcosystemContract.SystemContext)] = L2PlanFixtures.bytecodeInfo(SYSTEM_CONTEXT_IMPL_CODE);
        bytes memory shell = L2PlanFixtures.bytecodeInfo(SYSTEM_PROXY_CODE);

        IComplexUpgrader.UniversalContractUpgradeInfo[] memory derived = TransitionDerivationLib
            .deriveL2DeploymentsFromTable(table, shell);

        // Only the nonempty rows become deployments, in enum order, each at its member's
        // canonical fixed address, each carrying the `(implementation, proxy)` pair the L2 side
        // decodes — the shared shell joined to the member's own row.
        assertEq(derived.length, 2, "empty rows must derive no deployment");
        assertTrue(derived[0].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade);
        assertEq(
            derived[0].deployedBytecodeInfo,
            L2PlanFixtures.systemProxyRow(BRIDGEHUB_IMPL_CODE, SYSTEM_PROXY_CODE),
            "row = (implementation, shell)"
        );
        assertEq(derived[0].newAddress, L2InventoryLib.fixedAddress(L2EcosystemContract.L2Bridgehub));
        assertTrue(derived[1].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSSystemProxyUpgrade);
        assertEq(
            derived[1].deployedBytecodeInfo,
            L2PlanFixtures.systemProxyRow(SYSTEM_CONTEXT_IMPL_CODE, SYSTEM_PROXY_CODE),
            "every row is joined to the SAME shell"
        );
        assertEq(derived[1].newAddress, L2InventoryLib.fixedAddress(L2EcosystemContract.SystemContext));
    }

    /// @dev The shell is stored once on the release and served beside the table.
    function test_releaseServesTheSharedSystemProxyShell() public {
        CTMRelease release = _tableRelease();
        assertEq(release.l2SystemProxyBytecodeInfo(), L2PlanFixtures.bytecodeInfo(SYSTEM_PROXY_CODE));
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

    function test_transitionL2PlanIsDerivedPlusConstructedAuthored() public {
        CTMRelease tableRelease = _tableRelease();
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(tableRelease);
        CTMTransition combined = new CTMTransition(manifest);

        // The FINAL plan: the target release's table-derived set first, then the authored
        // bytecodes as Unsafe deployments — the delegate first, the extra after.
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory expectedDerived = TransitionDerivationLib
            .deriveL2DeploymentsFromTable(tableRelease.l2BytecodeInfos(), tableRelease.l2SystemProxyBytecodeInfo());
        IComplexUpgrader.UniversalContractUpgradeInfo[] memory expectedAuthored = _authoredDeployments();
        L2UpgradePlan memory plan = combined.l2Plan();
        assertEq(
            plan.deployments.length,
            expectedDerived.length + expectedAuthored.length,
            "final plan must be derived ++ authored"
        );
        for (uint256 i = 0; i < expectedDerived.length; ++i) {
            assertEq(abi.encode(plan.deployments[i]), abi.encode(expectedDerived[i]), "derived prefix mismatch");
        }
        for (uint256 i = 0; i < expectedAuthored.length; ++i) {
            assertEq(
                abi.encode(plan.deployments[expectedDerived.length + i]),
                abi.encode(expectedAuthored[i]),
                "authored suffix mismatch"
            );
        }
        assertEq(plan.delegateTo, expectedAuthored[0].newAddress, "the delegate is the first authored deployment");
        assertEq(plan.delegateComposer, address(delegateComposer), "the pinned composer is served");
        // The factory dependencies are CONSTRUCTED from what the deployments install: each table
        // row's implementation and the shared proxy shell (once), then the authored bytecodes.
        assertEq(plan.factoryDepHashes, _tableHopDeps(), "constructed factory dependencies");
        // ...and the composed transaction executes the COMBINED deployments, then the delegate
        // with the calldata the pinned composer defines, carrying the constructed dependencies.
        L2CanonicalTransaction memory transaction = _l2Tx(combined);
        assertEq(
            transaction.data,
            abi.encodeCall(
                IComplexUpgrader.forceDeployAndUpgradeUniversal,
                (plan.deployments, plan.delegateTo, DELEGATE_CALLDATA)
            ),
            "composed data must be derived ++ authored, delegate, composer calldata"
        );
        assertEq(transaction.factoryDeps, plan.factoryDepHashes, "the transaction carries the constructed deps");
    }

    /// @dev The L2 set is derived from the release PAIR: a member whose descriptor is identical in
    ///      both releases is not touched, so a facet-only or verifier-only upgrade toward a release
    ///      carrying the same table has no L2 leg at all — no delegate, no factory dependency.
    function test_transitionDerivesNoL2RowsWhenTheTableIsUnchanged() public {
        CTMRelease departing = _tableRelease();
        CTMRelease target = _tableRelease();
        TransitionManifest memory manifest = _transitionManifest();
        manifest.fromRelease = address(departing);
        manifest.newRelease = address(target);
        manifest.l2Plan = L2PlanFixtures.emptyPlan();
        CTMTransition l1Only = new CTMTransition(manifest);

        assertEq(l1Only.l2Plan().deployments.length, 0, "identical table rows derive no L2 deployment");
        assertEq(_l2Tx(l1Only).txType, 0, "an unchanged table composes the all-zero L2 transaction");
    }

    /// @dev Only the members whose descriptor changed are derived (a member new to the set counts as
    ///      changed); the rows identical to the departing release stay out of the L2 leg.
    function test_transitionDerivesOnlyTheChangedL2Rows() public {
        CTMRelease departing = _tableRelease();
        ReleaseManifest memory targetManifest = _newReleaseManifest();
        // Unchanged member, changed implementation, member new to the set.
        targetManifest.l2BytecodeInfos[uint256(L2EcosystemContract.L2Bridgehub)] = L2PlanFixtures.bytecodeInfo(
            BRIDGEHUB_IMPL_CODE
        );
        targetManifest.l2BytecodeInfos[uint256(L2EcosystemContract.SystemContext)] = L2PlanFixtures.bytecodeInfo(
            CHANGED_SYSTEM_CONTEXT_IMPL_CODE
        );
        targetManifest.l2BytecodeInfos[uint256(L2EcosystemContract.L2AssetRouter)] = L2PlanFixtures.bytecodeInfo(
            ASSET_ROUTER_IMPL_CODE
        );
        CTMRelease target = new CTMRelease(targetManifest);
        TransitionManifest memory manifest = _transitionManifest();
        manifest.fromRelease = address(departing);
        manifest.newRelease = address(target);
        manifest.l2Plan = _l2Plan();
        CTMTransition transition = new CTMTransition(manifest);

        L2UpgradePlan memory plan = transition.l2Plan();
        assertEq(plan.deployments.length, 4, "only the two changed members are derived, then the authored two");
        // Derived rows follow the table (member) order: L2AssetRouter precedes SystemContext.
        assertEq(
            plan.deployments[0].newAddress,
            L2InventoryLib.fixedAddress(L2EcosystemContract.L2AssetRouter),
            "the member new to the set is derived"
        );
        assertEq(
            plan.deployments[1].newAddress,
            L2InventoryLib.fixedAddress(L2EcosystemContract.SystemContext),
            "the member whose implementation changed is derived"
        );
        assertEq(
            plan.deployments[1].deployedBytecodeInfo,
            L2PlanFixtures.systemProxyRow(CHANGED_SYSTEM_CONTEXT_IMPL_CODE, SYSTEM_PROXY_CODE),
            "the derived row carries the TARGET release's implementation behind its shell"
        );
        // Only the CHANGED rows' bytecodes are dependencies: the unchanged L2Bridgehub
        // implementation is not installed, so it does not ride.
        assertEq(
            plan.factoryDepHashes,
            L2PlanFixtures.factoryDepHashes(
                L2PlanFixtures.codes(
                    ASSET_ROUTER_IMPL_CODE,
                    SYSTEM_PROXY_CODE,
                    CHANGED_SYSTEM_CONTEXT_IMPL_CODE,
                    DELEGATE_CODE,
                    EXTRA_CODE
                )
            ),
            "dependencies follow the derived rows (member order), then the authored bytecodes"
        );
    }

    /// @dev A shell change alone is not an L2 delta: an existing member's proxy is never
    ///      redeployed by `updateZKsyncOSContract`, so only implementation rows are compared.
    function test_transitionDerivesNoL2RowsWhenOnlyTheShellChanges() public {
        CTMRelease departing = _tableRelease();
        ReleaseManifest memory targetManifest = _tableReleaseManifest();
        targetManifest.l2SystemProxyBytecodeInfo = L2PlanFixtures.bytecodeInfo(CHANGED_SYSTEM_PROXY_CODE);
        CTMRelease target = new CTMRelease(targetManifest);
        TransitionManifest memory manifest = _transitionManifest();
        manifest.fromRelease = address(departing);
        manifest.newRelease = address(target);
        manifest.l2Plan = L2PlanFixtures.emptyPlan();

        CTMTransition shellOnly = new CTMTransition(manifest);

        assertEq(shellOnly.l2Plan().deployments.length, 0, "a shell-only change derives no L2 deployment");
    }

    /// @dev The enum is append-only: a departing release built against a shorter enum has no row
    ///      to compare for the appended members, which therefore count as changed.
    function test_changedL2RowsTreatsAppendedMembersAsChanged() public pure {
        bytes[] memory fromTable = new bytes[](1);
        fromTable[0] = hex"01";
        bytes[] memory newTable = new bytes[](3);
        newTable[0] = hex"01";
        newTable[2] = hex"02";

        bytes[] memory changed = TransitionDerivationLib.changedL2Rows(fromTable, newTable);

        assertEq(changed.length, 3, "the diff is indexed like the target table");
        assertEq(changed[0].length, 0, "an identical row is not a change");
        assertEq(changed[1].length, 0, "an empty target row is never a change");
        assertEq(changed[2], hex"02", "a row past the departing table's length is a change");
    }

    function test_revertWhen_derivedDeploymentsWithoutDelegateTarget() public {
        // The shape rules run against the COMBINED plan: a derived-nonempty transition with no
        // delegate target is unexecutable on L2 even when the manifest authors NO extras.
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(_tableRelease());
        manifest.l2Plan = L2PlanFixtures.emptyPlan();

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    // ─────────────────────────── authored L2 plan construction ───────────────────────────
    // The manifest names bytecodes; the object constructs everything else of the L2 side (see
    // L2PlanLib): one Unsafe deployment per authored bytecode info at its bytecode-derived
    // address, the delegate target, and the deduplicated factory dependencies. What cannot be
    // constructed into an executable plan refuses to exist.

    function test_authoredPlanIsConstructedFromItsBytecodeInfos() public view {
        L2UpgradePlan memory plan = transition.l2Plan();
        AuthoredL2Plan memory authored = _l2Plan();

        // No table rows on the target release: the final plan IS the constructed authored set.
        assertEq(plan.deployments.length, 2, "the delegate and the extra");
        for (uint256 i = 0; i < plan.deployments.length; ++i) {
            assertTrue(
                plan.deployments[i].upgradeType == IComplexUpgrader.ContractUpgradeType.ZKsyncOSUnsafeForceDeployment,
                "authored bytecodes are Unsafe deployments"
            );
            assertEq(
                plan.deployments[i].newAddress,
                L2GenesisForceDeploymentsHelper.generateRandomAddress(plan.deployments[i].deployedBytecodeInfo),
                "each sits at its bytecode-derived address"
            );
        }
        assertEq(plan.deployments[0].deployedBytecodeInfo, authored.delegateBytecodeInfo, "the delegate comes first");
        assertEq(plan.deployments[1].deployedBytecodeInfo, authored.extraBytecodeInfos[0], "the extra follows");
        assertEq(plan.delegateTo, plan.deployments[0].newAddress, "the delegate target is its derived address");
        assertEq(plan.delegateComposer, address(delegateComposer));
        assertEq(
            plan.factoryDepHashes,
            L2PlanFixtures.factoryDepHashes(L2PlanFixtures.codes(DELEGATE_CODE, EXTRA_CODE)),
            "the dependencies are the observable hashes of the authored bytecodes"
        );
    }

    /// @dev An L1-only hop: no delegate, no extras, no composer. The plan constructs to nothing.
    function test_l1OnlyTransitionWithoutL2PlanInitializes() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan = L2PlanFixtures.emptyPlan();

        CTMTransition l1Only = new CTMTransition(manifest);

        L2UpgradePlan memory plan = l1Only.l2Plan();
        assertEq(plan.deployments.length, 0, "an L1-only hop deploys nothing on L2");
        assertEq(plan.delegateTo, address(0));
        assertEq(plan.delegateComposer, address(0));
        // No L2 side: the composer emits the all-zero transaction `BaseZkSyncUpgrade` skips.
        assertEq(_l2Tx(l1Only).txType, 0, "an L1-only hop composes no L2 transaction");
    }

    function test_revertWhen_delegateBytecodeInfoIsMalformed() public {
        TransitionManifest memory manifest = _transitionManifest();
        // Not a canonical (blake, length, keccak) tuple: no address can be derived from it.
        manifest.l2Plan.delegateBytecodeInfo = hex"aa01";

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    function test_revertWhen_extraBytecodeInfoIsMalformed() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.l2Plan.extraBytecodeInfos[0] = hex"aa02";

        vm.expectRevert(MalformedL2UpgradePlan.selector);
        new CTMTransition(manifest);
    }

    /// @dev Factory dependencies are one entry per DISTINCT bytecode: the proxy shell shared by
    ///      every table row rides once, and an authored bytecode identical to a table row's
    ///      implementation adds nothing.
    function test_constructedFactoryDepsAreDeduplicated() public {
        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(_tableRelease());
        manifest.l2Plan = L2PlanFixtures.delegatePlanWithExtra(
            DELEGATE_CODE,
            BRIDGEHUB_IMPL_CODE,
            address(delegateComposer)
        );
        CTMTransition deduplicated = new CTMTransition(manifest);

        L2UpgradePlan memory plan = deduplicated.l2Plan();
        assertEq(plan.deployments.length, 4, "two table rows, the delegate, the extra");
        assertEq(
            plan.factoryDepHashes,
            L2PlanFixtures.factoryDepHashes(
                L2PlanFixtures.codes(BRIDGEHUB_IMPL_CODE, SYSTEM_PROXY_CODE, SYSTEM_CONTEXT_IMPL_CODE, DELEGATE_CODE)
            ),
            "the shared shell and the duplicated implementation ride once each, first occurrence wins"
        );
    }

    // ─────────────────────────── routing hygiene ───────────────────────────

    function test_releaseDoesNotValidateRouting() public {
        // Deliberate non-check: a facet describing no selectors constructs fine — the release is
        // pinned data, and `Diamond.diamondCut` rejects empty routing (`NoFunctionsForDiamondCut`)
        // when a chain is actually created from it.
        address emptyFacet = address(new MockSelfDescribingFacet(new bytes4[](0)));
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].facet = emptyFacet;

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

    function test_revertWhen_releaseNamesCodelessFacet() public {
        // A facet must be ACTUAL code: the release reads its routing out of it, and a codeless
        // address answers that read with an empty revert. Refused by `validate()`, which holds the
        // requirement on every execution path. The facet self-describes normally at construction;
        // its code is stripped afterwards to model a member that no longer carries code at
        // validation time.
        address codeless = address(new MockSelfDescribingFacet(_selectors1(bytes4(uint32(0x99)))));
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[0].facet = codeless;
        CTMRelease codelessRelease = new CTMRelease(manifest);
        vm.etch(codeless, "");

        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, codeless));
        codelessRelease.validate();
    }

    function test_revertWhen_transitionDerivesTowardSelectorCollision() public {
        // A selector routed twice constructs as a release (pinned data, no routing ownership) but
        // is rejected when a transition derives toward it — pre-commit, so a malformed routing
        // can never strand chains behind a bumped CTM version.
        // The colliding facet self-describes a selector facetFrozen also carries (0x20).
        address collidingFacet = address(new MockSelfDescribingFacet(_selectors1(bytes4(uint32(0x20)))));
        ReleaseManifest memory manifest = _newReleaseManifest();
        manifest.genesisFacets[1].facet = collidingFacet;
        CTMRelease collidingRelease = new CTMRelease(manifest);

        TransitionManifest memory transitionManifest = _transitionManifest();
        transitionManifest.newRelease = address(collidingRelease);

        vm.expectRevert(abi.encodeWithSelector(RegistryDuplicateSelector.selector, bytes4(uint32(0x20))));
        new CTMTransition(transitionManifest);
    }

    // ─────────────────────────── release provenance ───────────────────────────

    function test_transitionDefersReleaseProvenanceToCtm() public {
        // Which release object is genuine is deliberately NOT a transition concern: a
        // permissionless manifest could name any object, so the transition validates only each
        // edge's routing and members, and leaves WHICH object is trusted to governance reviewing
        // the deployed release the CTM is pointed at. So a hand-deployed but VALID release is
        // accepted here and derives a normal delta.
        CTMRelease handDeployed = new CTMRelease(_newReleaseManifest());

        TransitionManifest memory manifest = _transitionManifest();
        manifest.newRelease = address(handDeployed);

        CTMTransition deferred = new CTMTransition(manifest);
        assertEq(deferred.newRelease(), address(handDeployed), "transition accepts a valid hand-deployed release");
    }

    // ─────────────────────────── named members must be deployed ───────────────────────────

    function test_revertWhen_transitionEngineHasNoCode() public {
        // The engine is the committed cut's init delegatecall target: a codeless one would make
        // every chain's upgrade a no-op delegatecall that silently "succeeds".
        CTMTransition committed = new CTMTransition(_transitionManifest());

        vm.etch(upgradeEngine, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, upgradeEngine));
        committed.validate();
    }

    /// @dev The verifier belongs to the release along with the rest of the installed chain state.
    function test_revertWhen_releaseVerifierHasNoCode() public {
        CTMRelease committed = new CTMRelease(_newReleaseManifest());

        vm.etch(verifier, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, verifier));
        committed.validate();
    }

    function test_validateRejectsAMemberThatLostItsCode() public {
        coreRegistry.validate();
        newRelease.validate();
        transition.validate();

        // Empty one facet of the FROM release: the release, and transitively the transition
        // (which validates both edges), must stop validating.
        vm.etch(facetOldAdmin, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, facetOldAdmin));
        fromRelease.validate();
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, facetOldAdmin));
        transition.validate();

        // Same for the core registry's named implementation.
        vm.etch(coreImplNew, "");
        vm.expectRevert(abi.encodeWithSelector(RegistryTargetHasNoCode.selector, coreImplNew));
        coreRegistry.validate();
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
        manifest.proxyUpgrades[uint256(L1EcosystemContract.L1Bridgehub)].implNew = address(0);

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
    function test_operationRowsCarryTheirNamedAdmin() public {
        OperationManifest memory manifest = _operationManifest();
        manifest.ctmInfrastructure = _ctmInventoryWithTwoRows();

        EcosystemUpgradeOperation withRows = new EcosystemUpgradeOperation(manifest);
        ProxyUpgradeRow[] memory rows = withRows.ctmInfrastructureRows();
        assertEq(rows.length, 2, "both participating slots become rows, in inventory order");
        assertEq(rows[0].proxy, address(0xC001));
        assertEq(address(rows[0].admin), address(0), "a bound-admin row names no admin");
        assertEq(rows[1].proxy, address(0xC002));
        assertEq(address(rows[1].admin), makeAddr("notifierAdmin"), "the notifier row names its own admin");
        assertEq(withRows.manifestHash(), keccak256(abi.encode(manifest)), "the admin is part of the commitment");
    }

    // ─────────────────────────── operation fixtures ───────────────────────────

    /// @dev The default operation: the fixture transition, no ecosystem leg, no infrastructure.
    function _operationManifest() internal view returns (OperationManifest memory) {
        return
            OperationManifest({
                coreRegistry: address(0),
                ctmInfrastructure: new ProxyUpgradeRow[](CTM_CONTRACT_COUNT),
                transition: address(transition),
                timer: upgradeTimer
            });
    }

    /// @dev Two participating CTM-domain slots: the CTM itself under the executor's bound admin,
    ///      and the ServerNotifier under its own.
    function _ctmInventoryWithTwoRows() internal returns (ProxyUpgradeRow[] memory inventory) {
        inventory = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        inventory[uint256(CTMContract.ChainTypeManager)] = ProxyUpgradeRow({
            proxy: address(0xC001),
            expectedOldImpl: address(0xC101),
            implNew: _deployedStub("ctmImplNew"),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(address(0))
        });
        inventory[uint256(CTMContract.ServerNotifier)] = ProxyUpgradeRow({
            proxy: address(0xC002),
            expectedOldImpl: address(0xC102),
            implNew: _deployedStub("notifierImplNew"),
            callInitializeUpgrade: false,
            admin: ProxyAdmin(makeAddr("notifierAdmin"))
        });
    }
}

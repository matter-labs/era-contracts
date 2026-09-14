// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {BaseZkSyncUpgrade} from "contracts/upgrades/BaseZkSyncUpgrade.sol";
import {DefaultUpgrade} from "contracts/upgrades/DefaultUpgrade.sol";
import {CTMRelease} from "contracts/upgrades/registry/objects/CTMRelease.sol";
import {CTMTransition} from "contracts/upgrades/registry/objects/CTMTransition.sol";
import {ICTMRelease} from "contracts/upgrades/registry/objects/ICTMRelease.sol";
import {ReleaseFacetReader} from "contracts/upgrades/registry/libraries/ReleaseFacetReader.sol";
import {IChainTypeManager} from "contracts/state-transition/IChainTypeManager.sol";
import {Diamond} from "contracts/state-transition/libraries/Diamond.sol";
import {L2CanonicalTransactionLib} from "contracts/state-transition/libraries/L2CanonicalTransactionLib.sol";
import {L2CanonicalTransaction} from "contracts/common/Messaging.sol";
import {SemVer} from "contracts/common/libraries/SemVer.sol";
import {PreviousUpgradeNotFinalized} from "contracts/upgrades/ZkSyncUpgradeErrors.sol";
import {TimeNotReached} from "contracts/common/L1ContractErrors.sol";

import {BaseUpgrade} from "./_SharedBaseUpgrade.t.sol";
import {BaseUpgradeUtils} from "./_SharedBaseUpgradeUtils.t.sol";
import {RegistryObjectsFixture} from "./_SharedRegistryObjects.t.sol";

contract DummyDefaultUpgrade is DefaultUpgrade, BaseUpgradeUtils {}

/// @notice `DefaultUpgrade.upgradeFromTransition` against REAL write-once objects: the engine is
///         handed nothing but the transition address and must read the derived facet cuts, the
///         version edge and schedule, the TARGET release's verifier and the L2 plan from it. The
///         engine under test plays the chain diamond (it is called directly, so its own diamond
///         storage is the chain's). The same path through a real CTM, executor and chain proxy is
///         covered by RegistryDrivenUpgrade.t.sol.
contract DefaultUpgradeTest is BaseUpgrade, RegistryObjectsFixture {
    DummyDefaultUpgrade internal engine;
    CTMRelease internal fromRelease;
    CTMRelease internal newRelease;
    address internal fromVerifier;
    address internal newVerifier;
    address internal mockBridgehub = makeAddr("mockBridgehub");

    bytes internal constant DELEGATE_CALLDATA = hex"beef";

    function setUp() public {
        engine = new DummyDefaultUpgrade();
        _prepareUpgrade();
        engine.setPriorityTxMaxGasLimit(1 ether);
        engine.setPriorityTxMaxPubdata(1000000);
        engine.setBridgehub(mockBridgehub);
        // The releases pin a ZKsync OS DiamondInit, so the composed transaction carries the ZKsync
        // OS upgrade type — which the chain accepts only when it runs ZKsync OS itself.
        engine.setZKsyncOS(true);

        _setUpRegistryObjects(true, DELEGATE_CALLDATA);
        fromVerifier = _pinned("fromVerifier");
        newVerifier = _pinned("newVerifier");
        fromRelease = _release(_departingFacets(), fromVerifier);
        newRelease = _release(_arrivingFacets(), newVerifier);

        // The chain under test runs the departing release: its routing installed, its verifier live.
        engine.applyFacetCuts(ReleaseFacetReader.newChainInstallations(ICTMRelease(address(fromRelease))));
        engine.setVerifier(fromVerifier);
    }

    function _defaultTransition(uint256 _upgradeTimestamp) internal returns (CTMTransition) {
        return
            _transition(
                fromRelease,
                newRelease,
                0,
                protocolVersion,
                _upgradeTimestamp,
                address(engine),
                _delegatePlan()
            );
    }

    function test_upgradeFromTransition_appliesTheCommittedTransition() public {
        CTMTransition transition = _defaultTransition(0);
        L2CanonicalTransaction memory expectedTx = _expectedL2Tx(transition.l2Plan(), protocolVersion);
        bytes32 expectedHash = keccak256(abi.encode(expectedTx));

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.NewProtocolVersion(0, protocolVersion);
        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.NewVerifier(fromVerifier, newVerifier);
        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(protocolVersion, expectedHash, expectedTx);
        bytes32 result = engine.upgradeFromTransition(address(transition));

        assertEq(result, Diamond.DIAMOND_INIT_SUCCESS_RETURN_VALUE, "the diamond-init success value");
        assertEq(engine.getProtocolVersion(), protocolVersion, "the version edge comes off the transition");
        assertEq(engine.getVerifier(), newVerifier, "the verifier comes off the TARGET release");
        assertEq(engine.getL2SystemContractsUpgradeTxHash(), expectedHash, "the composed transaction is committed");
        // The DERIVED delta, applied verbatim: the departing facet's selector is gone, the arriving
        // facet's is routed, the shared facet is untouched.
        assertEq(engine.facetAddress(SEL_DEPARTING), address(0), "the departing facet is removed");
        assertEq(engine.facetAddress(SEL_ARRIVING), facetArriving, "the arriving facet is installed");
        assertEq(engine.facetAddress(SEL_SHARED_A), facetShared, "the shared facet is untouched");
    }

    /// @dev A lagging chain: its CTM has already moved on to a later release, but the chain
    ///      executes the transition committed for ITS edge, whose target release names the
    ///      verifier. The mocked CTM is a tripwire — the engine must never ask it.
    function test_upgradeFromTransition_readsTheTargetReleaseNotTheCTMsLiveOne() public {
        address ctm = makeAddr("chainTypeManager");
        engine.setChainTypeManager(ctm);
        address laterVerifier = _pinned("laterVerifier");
        CTMRelease laterRelease = _release(_arrivingFacets(), laterVerifier);
        vm.mockCall(ctm, abi.encodeCall(IChainTypeManager.currentRelease, ()), abi.encode(address(laterRelease)));

        engine.upgradeFromTransition(address(_defaultTransition(0)));

        assertEq(engine.getVerifier(), newVerifier, "the transition's target release wins");
        assertTrue(engine.getVerifier() != laterVerifier, "the CTM's live release must not leak in");
    }

    /// @dev A verifier-only hop: same facets on both releases, no authored L2 side. The derived
    ///      cuts are empty and the composer yields the all-zero transaction the engine skips.
    function test_upgradeFromTransition_l1OnlyTransitionSetsNoL2Transaction() public {
        CTMRelease verifierOnly = _release(_departingFacets(), newVerifier);
        CTMTransition transition = _transition(
            fromRelease,
            verifierOnly,
            0,
            protocolVersion,
            0,
            address(engine),
            _emptyPlan()
        );

        vm.expectEmit(address(engine));
        emit BaseZkSyncUpgrade.UpgradeComplete(
            protocolVersion,
            bytes32(0),
            L2CanonicalTransactionLib.emptyL2CanonicalTransaction()
        );
        engine.upgradeFromTransition(address(transition));

        assertEq(engine.getL2SystemContractsUpgradeTxHash(), bytes32(0), "no L2 transaction on an L1-only hop");
        assertEq(engine.getVerifier(), newVerifier);
        assertEq(engine.getProtocolVersion(), protocolVersion);
        assertEq(engine.facetAddress(SEL_DEPARTING), facetDeparting, "no facet change on a verifier-only hop");
    }

    function test_revertWhen_upgradeFromTransition_beforeTheSchedule() public {
        uint256 scheduled = block.timestamp + 1 days;
        CTMTransition transition = _defaultTransition(scheduled);

        vm.expectRevert(abi.encodeWithSelector(TimeNotReached.selector, scheduled, block.timestamp));
        engine.upgradeFromTransition(address(transition));

        // Exactly at the schedule the edge is executable.
        vm.warp(scheduled);
        engine.upgradeFromTransition(address(transition));
        assertEq(engine.getProtocolVersion(), protocolVersion);
    }

    /// @dev A minor hop requires the previous L2 upgrade to have been finalized.
    function test_revertWhen_upgradeFromTransition_previousUpgradeNotFinalized() public {
        bytes32 pending = keccak256("pending");
        engine.setL2SystemContractsUpgradeTxHash(pending);
        CTMTransition transition = _defaultTransition(0);

        vm.expectRevert(abi.encodeWithSelector(PreviousUpgradeNotFinalized.selector, pending));
        engine.upgradeFromTransition(address(transition));
    }

    /// @dev A patch edge (0.1.0 -> 0.1.1) may swap the verifier while the previous minor's L2
    ///      upgrade is still pending; it carries no L2 transaction (the transition refuses one),
    ///      so the pending hash survives it — see `PatchCantSetUpgradeTxn` in BaseZkSyncUpgrade.t.sol
    ///      for the engine-side refusal and StorageRegistries.t.sol for the object-side one.
    function test_upgradeFromTransition_patchKeepsThePendingL2Upgrade() public {
        engine.setProtocolVersion(protocolVersion);
        bytes32 pending = keccak256("pending");
        engine.setL2SystemContractsUpgradeTxHash(pending);
        uint256 patchVersion = SemVer.packSemVer(0, 1, 1);
        CTMRelease patched = _release(_departingFacets(), newVerifier);
        CTMTransition patch = _transition(
            fromRelease,
            patched,
            protocolVersion,
            patchVersion,
            0,
            address(engine),
            _emptyPlan()
        );

        engine.upgradeFromTransition(address(patch));

        assertEq(engine.getProtocolVersion(), patchVersion);
        assertEq(engine.getVerifier(), newVerifier, "a patch may swap the verifier");
        assertEq(
            engine.getL2SystemContractsUpgradeTxHash(),
            pending,
            "a patch leaves the pending L2 upgrade untouched"
        );
    }

    /// @dev The off-chain read: the transaction `upgradeFromTransition` commits, before per-chain
    ///      substitution, composed for the given Bridgehub.
    function test_l2UpgradeTx_isTheComposedTransaction() public {
        CTMTransition transition = _defaultTransition(0);

        L2CanonicalTransaction memory served = engine.l2UpgradeTx(address(transition), mockBridgehub);

        assertEq(
            keccak256(abi.encode(served)),
            keccak256(abi.encode(_expectedL2Tx(transition.l2Plan(), protocolVersion))),
            "the served transaction is the composed one"
        );
        engine.upgradeFromTransition(address(transition));
        assertEq(engine.getL2SystemContractsUpgradeTxHash(), keccak256(abi.encode(served)), "and the committed one");
    }
}

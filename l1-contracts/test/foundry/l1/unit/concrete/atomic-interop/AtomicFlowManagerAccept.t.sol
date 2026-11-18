// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicInteropProofBuilder} from "./AtomicInteropProofBuilder.sol";
import {AtomicFlowFixtures} from "./AtomicFlowFixtures.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {
    AtomicFlow,
    AtomicFlowPreimage,
    AtomicFinalityProof,
    ImtProof,
    LegState,
    ATOMIC_ACCEPT_LEAF_TAG,
    ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED,
    ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerAcceptedBundleNotInFlow,
    ManagerAcceptedLegDestinationChainMismatch,
    ManagerCommittedLegDestinationChainMismatch,
    ManagerFlowDeadlinePassed,
    ManagerFlowPreimageVersionMismatch,
    ManagerLegAlreadyAccepted,
    ManagerLegChainIdsLengthMismatch,
    ManagerLegChainNotAllowed,
    ManagerLegChainNotRegistered,
    ManagerNotInteropHandler,
    ManagerProofCountMismatch,
    ProofSourceChainMismatch
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {IMTLeafValueMismatch} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_BUNDLE_VERSION, InteropBundle, InteropCall} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers accepted flows ({ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED}) in `AtomicFlowManager`: the
/// destination-side `accept`, the destination check `append` adds for them, and how finality and the
/// timeout refund treat the destinations' acceptances as commitments. See
/// {protocol-docs/atomicity/acceptance.md}.
/// @dev Manager + commitment tree run at their canonical predeploys. Finality and absence proofs are real
/// end-to-end per {AtomicInteropProofBuilder}, whose one oracle tree plays every remote chain; each proof's
/// chain binding is its `sourceChainId`. Bridgehub registration and the receive filter are stubbed: they
/// are owned by `L2Bridgehub` and covered there.
contract AtomicFlowManagerAcceptTest is AtomicInteropProofBuilder {
    /// @dev Remote chains of the flows below; each is aggregated at most once per test, as the builder
    /// requires.
    uint256 internal constant CHAIN_A = 271;
    uint256 internal constant CHAIN_B = 272;
    uint256 internal constant CHAIN_C = 273;
    uint256 internal constant CHAIN_D = 274;
    uint256 internal constant UNREGISTERED_CHAIN = 999;

    AtomicFlowManager internal manager;
    L2InteropCommitmentTree internal canonicalTree;

    function setUp() public {
        (manager, canonicalTree) = _deployAtomicPredeploys(SETTLEMENT_LAYER_CHAIN_ID, true);
        _setUpAtomicFixtures();

        uint256[4] memory remotes = [CHAIN_A, CHAIN_B, CHAIN_C, CHAIN_D];
        for (uint256 i = 0; i < remotes.length; ++i) {
            _setLegChainRegistered(remotes[i], true);
            _setLegSourceAllowed(remotes[i], true);
        }
        _setLegChainRegistered(UNREGISTERED_CHAIN, false);
    }

    // ============ helpers ============

    function _setLegChainRegistered(uint256 _chainId, bool _registered) internal {
        bytes32 assetId = _registered ? keccak256(abi.encode("base token asset id", _chainId)) : bytes32(0);
        vm.mockCall(
            L2_BRIDGEHUB_ADDR,
            abi.encodeWithSignature("baseTokenAssetId(uint256)", _chainId),
            abi.encode(assetId)
        );
    }

    function _acceptValue(bytes32 _flowId, bytes32 _bundleHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_ACCEPT_LEAF_TAG, _flowId, _bundleHash)));
    }

    /// @dev An accepted single-leg flow `_source -> _destination`.
    function _singleLegPreimage(
        bytes32 _leg,
        uint256 _source,
        uint256 _destination
    ) internal pure returns (AtomicFlowPreimage memory preimage) {
        bytes32[] memory legs = new bytes32[](1);
        legs[0] = _leg;
        uint256[] memory chains = new uint256[](2);
        chains[0] = _source;
        chains[1] = _destination;
        preimage = AtomicFlowFixtures.nLegPreimage(legs, chains, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED;
    }

    function _acceptAsHandler(bytes32 _bundleHash, AtomicFlowPreimage memory _preimage) internal {
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.accept(_bundleHash, 0, _preimage);
    }

    /// @dev A real encodable bundle from this chain to `_destination`, so `claimRefund` can re-derive its hash.
    /// No calls: these tests pin the leg state machine, not fund recovery (covered by the recovery suites).
    function _bundleTo(uint256 _destination) internal view returns (bytes memory bundleBytes, bytes32 bundleHash) {
        InteropBundle memory bundle = InteropBundle({
            version: INTEROP_BUNDLE_VERSION,
            sourceChainId: block.chainid,
            destinationChainId: _destination,
            destinationBaseTokenAssetId: bytes32(uint256(1)),
            interopBundleSalt: keccak256("accepted flow salt"),
            calls: new InteropCall[](0),
            bundleAttributes: AtomicFlowFixtures.noBundleAttributes()
        });
        bundleBytes = abi.encode(bundle);
        bundleHash = InteropDataEncoding.encodeInteropBundleHash(bundleBytes);
    }

    // ============ accept: happy path ============

    /// @notice The destination inserts the leg's accept value into its own IMT, records the acceptance
    /// and emits `FlowAccepted` with the leaf index.
    function test_accept_InsertsAcceptValueAndRecordsIt() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, block.chainid);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 expectedIndex = canonicalTree.leafCount();

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowAccepted(flowId, leg, DEADLINE, expectedIndex);
        _acceptAsHandler(leg, preimage);

        assertTrue(manager.legAccepted(flowId, leg), "acceptance recorded");
        assertEq(canonicalTree.leafAt(expectedIndex).value, _acceptValue(flowId, leg), "accept value in the IMT");
        assertEq(
            uint256(manager.legState(flowId, leg)),
            uint256(LegState.Unset),
            "no source-leg state on the destination"
        );
    }

    // ============ accept: reverts ============

    function test_accept_RevertWhen_NotInteropHandler() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, block.chainid);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropHandler.selector, L2_INTEROP_CENTER_ADDR));
        manager.accept(leg, 0, preimage);
    }

    /// @notice A source-only flow has no acceptances: its preimage declares no destinations to check.
    function test_accept_RevertWhen_SourceOnlyFlow() public {
        bytes32 leg = keccak256("incoming leg");
        bytes32[] memory legs = new bytes32[](1);
        legs[0] = leg;
        uint256[] memory chains = new uint256[](1);
        chains[0] = CHAIN_A;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            chains,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerFlowPreimageVersionMismatch.selector,
                ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED,
                ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY
            )
        );
        _acceptAsHandler(leg, preimage);
    }

    /// @notice An accepted flow must declare a destination per leg (`2n` chain ids).
    function test_accept_RevertWhen_DestinationsMissing() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, block.chainid);
        uint256[] memory sourcesOnly = new uint256[](1);
        sourcesOnly[0] = CHAIN_A;
        preimage.legChainIds = sourcesOnly;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainIdsLengthMismatch.selector, 2, 1));
        _acceptAsHandler(leg, preimage);
    }

    function test_accept_RevertWhen_BundleNotInFlow() public {
        AtomicFlowPreimage memory preimage = _singleLegPreimage(keccak256("incoming leg"), CHAIN_A, block.chainid);
        bytes32 stray = keccak256("stray bundle");

        vm.expectRevert(
            abi.encodeWithSelector(ManagerAcceptedBundleNotInFlow.selector, AtomicFlowFixtures.flowId(preimage), stray)
        );
        _acceptAsHandler(stray, preimage);
    }

    /// @notice A chain only accepts legs the preimage declares to it: a refund for a missing acceptance is
    /// proven against the declared destination's tree, so an acceptance anywhere else must not exist.
    function test_accept_RevertWhen_DeclaredDestinationIsAnotherChain() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, CHAIN_B);

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerAcceptedLegDestinationChainMismatch.selector,
                AtomicFlowFixtures.flowId(preimage),
                block.chainid,
                CHAIN_B
            )
        );
        _acceptAsHandler(leg, preimage);
    }

    function test_accept_RevertWhen_AlreadyAccepted() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, block.chainid);
        _acceptAsHandler(leg, preimage);

        vm.expectRevert(
            abi.encodeWithSelector(ManagerLegAlreadyAccepted.selector, AtomicFlowFixtures.flowId(preimage), leg)
        );
        _acceptAsHandler(leg, preimage);
    }

    /// @notice Same best-effort guard as `append`: once this chain imported a root past the deadline, an
    /// acceptance could only feed a flow that must be refunded.
    function test_accept_RevertWhen_DeadlinePassed() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, block.chainid);
        uint256 lateTimestamp = uint256(DEADLINE) + 1;
        _importInteropRoot(SETTLEMENT_LAYER_CHAIN_ID, _freshSlBlock(), lateTimestamp, keccak256("late root"));

        vm.expectRevert(abi.encodeWithSelector(ManagerFlowDeadlinePassed.selector, DEADLINE, lateTimestamp));
        _acceptAsHandler(leg, preimage);
    }

    /// @notice The destination refuses a flow it could never execute: one whose proofs it would not accept.
    function test_accept_RevertWhen_LegChainNotAllowed() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, block.chainid);
        _setLegSourceAllowed(CHAIN_A, false);

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotAllowed.selector, CHAIN_A));
        _acceptAsHandler(leg, preimage);
    }

    function test_accept_RevertWhen_LegChainNotRegistered() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, UNREGISTERED_CHAIN, block.chainid);

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotRegistered.selector, UNREGISTERED_CHAIN));
        _acceptAsHandler(leg, preimage);
    }

    // ============ append: declared destination ============

    /// @notice For an accepted flow the source checks its leg's declared destination against the bundle's,
    /// so a wrong preimage fails at send instead of leaving a flow that can only time out.
    function test_append_AcceptedFlow_RevertWhen_DestinationMismatch() public {
        bytes32 leg = keccak256("outgoing leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerCommittedLegDestinationChainMismatch.selector,
                AtomicFlowFixtures.flowId(preimage),
                CHAIN_B,
                CHAIN_A
            )
        );
        manager.append(leg, CHAIN_B, 0, preimage);
    }

    function test_append_AcceptedFlow_CommitsWithMatchingDestination() public {
        bytes32 leg = keccak256("outgoing leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(leg, CHAIN_A, 0, preimage);

        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Committed), "leg committed");
        assertFalse(manager.legAccepted(flowId, leg), "the source does not accept its own outgoing leg");
    }

    // ============ finality ============

    /// @dev Two legs `A -> C` and `B -> D`, with every commit and acceptance in the oracle tree. Returns the
    /// preimage and the four proofs in `legChainIds` order: commits on A and B, acceptances on C and D.
    function _twoLegAcceptedFlow(
        bool _withSecondAcceptance
    ) internal returns (AtomicFinalityProof memory finality, bytes32 legFirst, bytes32 legSecond) {
        bytes32 legX = keccak256("finalize leg X");
        bytes32 legY = keccak256("finalize leg Y");
        (legFirst, legSecond) = legX < legY ? (legX, legY) : (legY, legX);

        bytes32[] memory legs = new bytes32[](2);
        legs[0] = legFirst;
        legs[1] = legSecond;
        uint256[] memory chains = new uint256[](4);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_B;
        chains[2] = CHAIN_C;
        chains[3] = CHAIN_D;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            chains,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED;
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);

        uint256 commitFirst = _insertCommit(AtomicFlowFixtures.commitValue(flowId, legFirst));
        uint256 commitSecond = _insertCommit(AtomicFlowFixtures.commitValue(flowId, legSecond));
        uint256 acceptFirst = _insertCommit(_acceptValue(flowId, legFirst));
        // Without the second acceptance, its proof slot points at the first acceptance's leaf instead.
        uint256 acceptSecond = _withSecondAcceptance ? _insertCommit(_acceptValue(flowId, legSecond)) : acceptFirst;

        finality.flow = AtomicFlow({flowId: flowId, preimage: preimage});
        finality.proofs = new ImtProof[](4);
        finality.proofs[0] = _realInclusionProof(CHAIN_A, commitFirst, DEADLINE - 1);
        finality.proofs[1] = _realInclusionProof(CHAIN_B, commitSecond, DEADLINE - 1);
        finality.proofs[2] = _realInclusionProof(CHAIN_C, acceptFirst, DEADLINE - 1);
        finality.proofs[3] = _realInclusionProof(CHAIN_D, acceptSecond, DEADLINE - 1);
    }

    function _requireFinalizedAsHandler(bytes32 _executingBundleHash, AtomicFinalityProof memory _finality) internal {
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.requireFlowFinalized(_executingBundleHash, _finality);
    }

    /// @notice An accepted flow finalizes once every leg is committed on its source AND accepted on its
    /// destination in time.
    function test_requireFlowFinalized_AcceptedFlow_AllCommitmentsProven() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, bytes32 legSecond) = _twoLegAcceptedFlow(true);
        _requireFinalizedAsHandler(legFirst, finality);
        _requireFinalizedAsHandler(legSecond, finality);
    }

    /// @notice Source commits alone do not finalize an accepted flow.
    function test_requireFlowFinalized_AcceptedFlow_RevertWhen_AcceptanceProofsMissing() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, ) = _twoLegAcceptedFlow(true);
        ImtProof[] memory sourceProofs = new ImtProof[](2);
        sourceProofs[0] = finality.proofs[0];
        sourceProofs[1] = finality.proofs[1];
        finality.proofs = sourceProofs;

        vm.expectRevert(abi.encodeWithSelector(ManagerProofCountMismatch.selector, 4, 2));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice A leg its destination never accepted blocks the whole flow, including the accepted legs.
    function test_requireFlowFinalized_AcceptedFlow_RevertWhen_OneAcceptanceAbsent() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, bytes32 legSecond) = _twoLegAcceptedFlow(false);
        bytes32 flowId = finality.flow.flowId;

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                _acceptValue(flowId, legSecond),
                _acceptValue(flowId, legFirst)
            )
        );
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice An acceptance proof is bound to the leg's declared destination, like a commit proof to its source.
    function test_requireFlowFinalized_AcceptedFlow_RevertWhen_AcceptanceProofOnWrongChain() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, ) = _twoLegAcceptedFlow(true);
        finality.proofs[2].sourceChainId = CHAIN_D;

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, CHAIN_C, CHAIN_D));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    // ============ timeout refund ============

    /// @notice The single refund: a leg committed here whose destination did not accept it by the deadline
    /// becomes `Revertable` and is claimable, with no step on the destination.
    function test_authorizeRefund_AcceptedFlow_RefundsWhenAcceptanceMissing() public {
        (bytes memory bundleBytes, bytes32 leg) = _bundleTo(CHAIN_A);
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(leg, CHAIN_A, 0, preimage);

        // Index 1 = the leg's acceptance on CHAIN_A (commitments are laid out as `legChainIds`).
        uint256 acceptanceIndex = 1;
        ImtProof memory absence = _realTimeoutBeginProof(CHAIN_A, _acceptValue(flowId, leg), uint256(DEADLINE) + 1);

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefundAuthorized(flowId, leg);
        manager.authorizeRefund(AtomicFlow({flowId: flowId, preimage: preimage}), acceptanceIndex, absence);
        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Revertable), "leg revertable");

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(flowId, leg);
        manager.claimRefund(flowId, bundleBytes);
        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Reverted), "leg reverted");
    }

    /// @notice The double-mint guard covers acceptances too: the absence must be proven on the declared
    /// destination, since an accept value is trivially absent from every other chain's tree.
    function test_authorizeRefund_AcceptedFlow_RevertWhen_AbsenceOnWrongChain() public {
        (, bytes32 leg) = _bundleTo(CHAIN_A);
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(leg, CHAIN_A, 0, preimage);

        ImtProof memory absence = _realTimeoutBeginProof(CHAIN_B, _acceptValue(flowId, leg), uint256(DEADLINE) + 1);

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, CHAIN_A, CHAIN_B));
        manager.authorizeRefund(AtomicFlow({flowId: flowId, preimage: preimage}), 1, absence);
        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Committed), "leg still committed");
    }
}

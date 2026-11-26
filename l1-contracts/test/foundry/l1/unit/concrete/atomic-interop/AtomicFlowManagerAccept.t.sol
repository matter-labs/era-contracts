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
    ATOMIC_PARTICIPATION_LEAF_TAG,
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
import {IMTLeafValueMismatch, IMTLowLeafNextTooSmall} from "contracts/common/L1ContractErrors.sol";
import {INTEROP_BUNDLE_VERSION, InteropBundle, InteropCall} from "contracts/common/Messaging.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {
    L2_BRIDGEHUB_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_HANDLER_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers accepted flows ({ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED}) in `AtomicFlowManager`: the
/// destination-side `accept`, the destination check `append` adds for them, the one participation value each
/// chain inserts after its last step, and how finality and the timeout refund prove those values. See
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
            _setLegChainAllowed(remotes[i], true);
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

    function _participationValue(bytes32 _flowId, uint256 _chainId) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_PARTICIPATION_LEAF_TAG, _flowId, _chainId)));
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

    /// @dev A two-leg accepted flow between this chain and `_peer`: leg `_outgoing` from here to `_peer`, leg
    /// `_incoming` from `_peer` to here (a swap).
    function _swapPreimage(
        bytes32 _outgoing,
        bytes32 _incoming,
        uint256 _peer
    ) internal view returns (AtomicFlowPreimage memory preimage) {
        bool outgoingFirst = _outgoing < _incoming;
        bytes32[] memory legs = new bytes32[](2);
        legs[0] = outgoingFirst ? _outgoing : _incoming;
        legs[1] = outgoingFirst ? _incoming : _outgoing;
        uint256[] memory chains = new uint256[](4);
        // Sources of legs[0], legs[1], then their destinations.
        chains[0] = outgoingFirst ? block.chainid : _peer;
        chains[1] = outgoingFirst ? _peer : block.chainid;
        chains[2] = chains[1];
        chains[3] = chains[0];
        preimage = AtomicFlowFixtures.nLegPreimage(legs, chains, DEADLINE, SETTLEMENT_LAYER_CHAIN_ID);
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED;
    }

    function _appendAsCenter(bytes32 _bundleHash, uint256 _destination, AtomicFlowPreimage memory _preimage) internal {
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(_bundleHash, _destination, 0, _preimage);
    }

    // ============ participation ============

    /// @notice A pure destination's only step is accepting its incoming leg, so that acceptance inserts the
    /// chain's participation value.
    function test_accept_SingleIncomingLeg_InsertsParticipation() public {
        bytes32 leg = keccak256("incoming leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, CHAIN_A, block.chainid);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 expectedIndex = canonicalTree.leafCount();

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowAccepted(flowId, leg);
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowParticipated(flowId, DEADLINE, expectedIndex);
        _acceptAsHandler(leg, preimage);

        assertTrue(manager.legAccepted(flowId, leg), "acceptance recorded");
        assertEq(canonicalTree.leafCount(), expectedIndex + 1, "one leaf for the chain");
        assertEq(
            canonicalTree.leafAt(expectedIndex).value,
            _participationValue(flowId, block.chainid),
            "participation value in the IMT"
        );
        assertEq(
            uint256(manager.legState(flowId, leg)),
            uint256(LegState.Unset),
            "no source-leg state on the destination"
        );
    }

    /// @notice A pure source's only step is committing its leg, so the send inserts the chain's participation
    /// value instead of a per-leg commit value.
    function test_append_AcceptedFlow_PureSource_InsertsParticipation() public {
        bytes32 leg = keccak256("outgoing leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 expectedIndex = canonicalTree.leafCount();

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowLegCommitted(flowId, leg);
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowParticipated(flowId, DEADLINE, expectedIndex);
        _appendAsCenter(leg, CHAIN_A, preimage);

        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Committed), "leg committed");
        assertFalse(manager.legAccepted(flowId, leg), "the source does not accept its own outgoing leg");
        assertEq(canonicalTree.leafCount(), expectedIndex + 1, "one leaf for the chain");
        assertEq(
            canonicalTree.leafAt(expectedIndex).value,
            _participationValue(flowId, block.chainid),
            "participation value, not a commit value"
        );
    }

    /// @notice In a swap the chain both sends and receives: accepting the incoming leg first inserts nothing,
    /// and the later send of the outgoing leg inserts the chain's single participation value.
    function test_swap_AcceptThenSend_InsertsOneLeaf() public {
        bytes32 outgoing = keccak256("swap outgoing");
        bytes32 incoming = keccak256("swap incoming");
        AtomicFlowPreimage memory preimage = _swapPreimage(outgoing, incoming, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 leavesBefore = canonicalTree.leafCount();

        _acceptAsHandler(incoming, preimage);
        assertTrue(manager.legAccepted(flowId, incoming), "incoming leg accepted");
        assertEq(canonicalTree.leafCount(), leavesBefore, "no leaf while the outgoing leg is uncommitted");

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowParticipated(flowId, DEADLINE, leavesBefore);
        _appendAsCenter(outgoing, CHAIN_A, preimage);

        assertEq(canonicalTree.leafCount(), leavesBefore + 1, "one leaf for both steps");
        assertEq(canonicalTree.leafAt(leavesBefore).value, _participationValue(flowId, block.chainid));
    }

    /// @notice Same swap in the other order: the send inserts nothing, the acceptance inserts the leaf.
    function test_swap_SendThenAccept_InsertsOneLeaf() public {
        bytes32 outgoing = keccak256("swap outgoing");
        bytes32 incoming = keccak256("swap incoming");
        AtomicFlowPreimage memory preimage = _swapPreimage(outgoing, incoming, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 leavesBefore = canonicalTree.leafCount();

        _appendAsCenter(outgoing, CHAIN_A, preimage);
        assertEq(uint256(manager.legState(flowId, outgoing)), uint256(LegState.Committed), "outgoing committed");
        assertEq(canonicalTree.leafCount(), leavesBefore, "no leaf while the incoming leg is unaccepted");

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowParticipated(flowId, DEADLINE, leavesBefore);
        _acceptAsHandler(incoming, preimage);

        assertEq(canonicalTree.leafCount(), leavesBefore + 1, "one leaf for both steps");
        assertEq(canonicalTree.leafAt(leavesBefore).value, _participationValue(flowId, block.chainid));
    }

    /// @notice A chain that sends several legs of one flow inserts one leaf, on its last send.
    function test_append_AcceptedFlow_TwoOutgoingLegs_OneLeaf() public {
        bytes32 legX = keccak256("fan-out leg X");
        bytes32 legY = keccak256("fan-out leg Y");
        (bytes32 legFirst, bytes32 legSecond) = legX < legY ? (legX, legY) : (legY, legX);
        bytes32[] memory legs = new bytes32[](2);
        legs[0] = legFirst;
        legs[1] = legSecond;
        uint256[] memory chains = new uint256[](4);
        chains[0] = block.chainid;
        chains[1] = block.chainid;
        chains[2] = CHAIN_A;
        chains[3] = CHAIN_B;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            chains,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED;
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 leavesBefore = canonicalTree.leafCount();

        _appendAsCenter(legFirst, CHAIN_A, preimage);
        assertEq(canonicalTree.leafCount(), leavesBefore, "no leaf after the first of two sends");

        _appendAsCenter(legSecond, CHAIN_B, preimage);
        assertEq(canonicalTree.leafCount(), leavesBefore + 1, "one leaf after the last send");
        assertEq(canonicalTree.leafAt(leavesBefore).value, _participationValue(flowId, block.chainid));
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
        _setLegChainAllowed(CHAIN_A, false);

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

    /// @notice The registration gate scans all `2n` entries of an accepted flow: an unregistered declared
    /// destination (`legChainIds[n]` here) is rejected at send, as its acceptance could never be proven.
    function test_append_AcceptedFlow_RevertWhen_DestinationChainNotRegistered() public {
        bytes32 leg = keccak256("outgoing leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, UNREGISTERED_CHAIN);

        vm.prank(L2_INTEROP_CENTER_ADDR);
        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotRegistered.selector, UNREGISTERED_CHAIN));
        manager.append(leg, UNREGISTERED_CHAIN, 0, preimage);
    }

    // ============ finality ============

    /// @dev Two legs `A -> C` and `B -> D`: four participating chains, each with its participation value in
    /// the oracle tree. Returns the preimage and the four proofs in first-appearance order of `legChainIds`.
    function _twoLegAcceptedFlow(
        bool _withLastParticipation
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

        uint256 leafA = _insertCommit(_participationValue(flowId, CHAIN_A));
        uint256 leafB = _insertCommit(_participationValue(flowId, CHAIN_B));
        uint256 leafC = _insertCommit(_participationValue(flowId, CHAIN_C));
        // Without D's participation, its proof slot points at C's leaf instead.
        uint256 leafD = _withLastParticipation ? _insertCommit(_participationValue(flowId, CHAIN_D)) : leafC;

        finality.flow = AtomicFlow({flowId: flowId, preimage: preimage});
        finality.proofs = new ImtProof[](4);
        finality.proofs[0] = _realInclusionProof(CHAIN_A, leafA, DEADLINE - 1);
        finality.proofs[1] = _realInclusionProof(CHAIN_B, leafB, DEADLINE - 1);
        finality.proofs[2] = _realInclusionProof(CHAIN_C, leafC, DEADLINE - 1);
        finality.proofs[3] = _realInclusionProof(CHAIN_D, leafD, DEADLINE - 1);
    }

    /// @dev A swap `A -> B`, `B -> A`: `legChainIds` lists each chain twice, but each participates once.
    function _swapAcceptedFlow() internal returns (AtomicFinalityProof memory finality, bytes32 legFirst) {
        bytes32 legX = keccak256("swap leg X");
        bytes32 legY = keccak256("swap leg Y");
        bytes32 legSecond;
        (legFirst, legSecond) = legX < legY ? (legX, legY) : (legY, legX);

        bytes32[] memory legs = new bytes32[](2);
        legs[0] = legFirst;
        legs[1] = legSecond;
        uint256[] memory chains = new uint256[](4);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_B;
        chains[2] = CHAIN_B;
        chains[3] = CHAIN_A;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            chains,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        preimage.version = ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED;
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);

        uint256 leafA = _insertCommit(_participationValue(flowId, CHAIN_A));
        uint256 leafB = _insertCommit(_participationValue(flowId, CHAIN_B));

        finality.flow = AtomicFlow({flowId: flowId, preimage: preimage});
        finality.proofs = new ImtProof[](2);
        finality.proofs[0] = _realInclusionProof(CHAIN_A, leafA, DEADLINE - 1);
        finality.proofs[1] = _realInclusionProof(CHAIN_B, leafB, DEADLINE - 1);
    }

    function _requireFinalizedAsHandler(bytes32 _executingBundleHash, AtomicFinalityProof memory _finality) internal {
        vm.prank(L2_INTEROP_HANDLER_ADDR);
        manager.requireFlowFinalized(_executingBundleHash, _finality);
    }

    /// @notice An accepted flow finalizes once every participating chain's participation value is in time.
    function test_requireFlowFinalized_AcceptedFlow_AllParticipationsProven() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, bytes32 legSecond) = _twoLegAcceptedFlow(true);
        _requireFinalizedAsHandler(legFirst, finality);
        _requireFinalizedAsHandler(legSecond, finality);
    }

    /// @notice A swap needs one proof per chain, not per leg end: two proofs for two legs.
    function test_requireFlowFinalized_Swap_TwoProofs() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst) = _swapAcceptedFlow();
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice A swap's proofs must be one per distinct chain; a per-leg-end proof list is rejected.
    function test_requireFlowFinalized_Swap_RevertWhen_ProofPerLegEnd() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst) = _swapAcceptedFlow();
        ImtProof[] memory perLegEnd = new ImtProof[](4);
        perLegEnd[0] = finality.proofs[0];
        perLegEnd[1] = finality.proofs[1];
        perLegEnd[2] = finality.proofs[1];
        perLegEnd[3] = finality.proofs[0];
        finality.proofs = perLegEnd;

        vm.expectRevert(abi.encodeWithSelector(ManagerProofCountMismatch.selector, 2, 4));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice Proofs follow each chain's first appearance in `legChainIds`, not its positions: a fan-out
    /// `A -> C`, `A -> D` lists `[A, A, C, D]` and takes the proofs `[A, C, D]`.
    function test_requireFlowFinalized_FanOut_ProofsInFirstAppearanceOrder() public {
        bytes32 legX = keccak256("fan-out leg X");
        bytes32 legY = keccak256("fan-out leg Y");
        bytes32[] memory legs = new bytes32[](2);
        (legs[0], legs[1]) = legX < legY ? (legX, legY) : (legY, legX);
        uint256[] memory chains = new uint256[](4);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_A;
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
        uint256 leafA = _insertCommit(_participationValue(flowId, CHAIN_A));
        uint256 leafC = _insertCommit(_participationValue(flowId, CHAIN_C));
        uint256 leafD = _insertCommit(_participationValue(flowId, CHAIN_D));

        AtomicFinalityProof memory finality;
        finality.flow = AtomicFlow({flowId: flowId, preimage: preimage});
        finality.proofs = new ImtProof[](3);
        finality.proofs[0] = _realInclusionProof(CHAIN_A, leafA, DEADLINE - 1);
        finality.proofs[1] = _realInclusionProof(CHAIN_C, leafC, DEADLINE - 1);
        finality.proofs[2] = _realInclusionProof(CHAIN_D, leafD, DEADLINE - 1);

        _requireFinalizedAsHandler(legs[0], finality);
    }

    /// @notice One proof per chain is for accepted flows only: a source-only flow with two legs from one chain
    /// still needs a proof per leg, or the second leg would finalize without being committed.
    function test_requireFlowFinalized_SourceOnly_RevertWhen_SharedSourceProvenOnce() public {
        bytes32 legX = keccak256("shared source leg X");
        bytes32 legY = keccak256("shared source leg Y");
        bytes32[] memory legs = new bytes32[](2);
        (legs[0], legs[1]) = legX < legY ? (legX, legY) : (legY, legX);
        uint256[] memory chains = new uint256[](2);
        chains[0] = CHAIN_A;
        chains[1] = CHAIN_A;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            chains,
            DEADLINE,
            SETTLEMENT_LAYER_CHAIN_ID
        );
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 leafFirst = _insertCommit(AtomicFlowFixtures.commitValue(flowId, legs[0]));

        AtomicFinalityProof memory finality;
        finality.flow = AtomicFlow({flowId: flowId, preimage: preimage});
        finality.proofs = new ImtProof[](1);
        finality.proofs[0] = _realInclusionProof(CHAIN_A, leafFirst, DEADLINE - 1);

        vm.expectRevert(abi.encodeWithSelector(ManagerProofCountMismatch.selector, 2, 1));
        _requireFinalizedAsHandler(legs[0], finality);
    }

    /// @notice Source chains alone do not finalize an accepted flow.
    function test_requireFlowFinalized_AcceptedFlow_RevertWhen_DestinationProofsMissing() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, ) = _twoLegAcceptedFlow(true);
        ImtProof[] memory sourceProofs = new ImtProof[](2);
        sourceProofs[0] = finality.proofs[0];
        sourceProofs[1] = finality.proofs[1];
        finality.proofs = sourceProofs;

        vm.expectRevert(abi.encodeWithSelector(ManagerProofCountMismatch.selector, 4, 2));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice A chain that never participated blocks the whole flow, and another chain's participation value
    /// cannot stand in for it.
    function test_requireFlowFinalized_AcceptedFlow_RevertWhen_OneParticipationAbsent() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, ) = _twoLegAcceptedFlow(false);
        bytes32 flowId = finality.flow.flowId;

        vm.expectRevert(
            abi.encodeWithSelector(
                IMTLeafValueMismatch.selector,
                _participationValue(flowId, CHAIN_D),
                _participationValue(flowId, CHAIN_C)
            )
        );
        _requireFinalizedAsHandler(legFirst, finality);
    }

    /// @notice A participation proof is bound to its chain, like a commit proof to its source.
    function test_requireFlowFinalized_AcceptedFlow_RevertWhen_ProofOnWrongChain() public {
        (AtomicFinalityProof memory finality, bytes32 legFirst, ) = _twoLegAcceptedFlow(true);
        finality.proofs[2].sourceChainId = CHAIN_D;

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, CHAIN_C, CHAIN_D));
        _requireFinalizedAsHandler(legFirst, finality);
    }

    // ============ timeout refund ============

    /// @notice The single refund: a leg committed here whose destination did not participate by the deadline
    /// becomes `Revertable` and is claimable, with no step on the destination.
    function test_authorizeRefund_AcceptedFlow_RefundsWhenDestinationParticipationMissing() public {
        (bytes memory bundleBytes, bytes32 leg) = _bundleTo(CHAIN_A);
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(leg, CHAIN_A, 0, preimage);
        // Decoy: the source's participation is in CHAIN_A's tree too, so a refund that proved the absence of
        // any value but the indexed chain's would fail.
        _insertCommit(_participationValue(flowId, block.chainid));

        // Index 1 names CHAIN_A, the leg's destination, in `legChainIds`.
        uint256 destinationIndex = 1;
        ImtProof memory absence = _realTimeoutBeginProof(
            CHAIN_A,
            _participationValue(flowId, CHAIN_A),
            uint256(DEADLINE) + 1
        );

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefundAuthorized(flowId, leg);
        manager.authorizeRefund(AtomicFlow({flowId: flowId, preimage: preimage}), destinationIndex, absence);
        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Revertable), "leg revertable");

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefunded(flowId, leg);
        manager.claimRefund(flowId, bundleBytes);
        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Reverted), "leg reverted");
    }

    /// @notice The double-mint guard covers participations too: the absence must be proven on the chain the
    /// index names, since its participation value is trivially absent from every other chain's tree.
    function test_authorizeRefund_AcceptedFlow_RevertWhen_AbsenceOnWrongChain() public {
        (, bytes32 leg) = _bundleTo(CHAIN_A);
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(leg, CHAIN_A, 0, preimage);

        ImtProof memory absence = _realTimeoutBeginProof(
            CHAIN_B,
            _participationValue(flowId, CHAIN_A),
            uint256(DEADLINE) + 1
        );

        vm.expectRevert(abi.encodeWithSelector(ProofSourceChainMismatch.selector, CHAIN_A, CHAIN_B));
        manager.authorizeRefund(AtomicFlow({flowId: flowId, preimage: preimage}), 1, absence);
        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Committed), "leg still committed");
    }

    /// @notice A destination that participated in time cannot be proven absent: the refund checks its
    /// participation value, whose predecessor leaf already links to it.
    function test_authorizeRefund_AcceptedFlow_RevertWhen_ParticipationPresent() public {
        (, bytes32 leg) = _bundleTo(CHAIN_A);
        AtomicFlowPreimage memory preimage = _singleLegPreimage(leg, block.chainid, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(leg, CHAIN_A, 0, preimage);
        uint256 present = _participationValue(flowId, CHAIN_A);
        _insertCommit(present);

        // A genuine late-batch proof, re-pointed at `present`'s predecessor: the only leaf that could
        // bracket it.
        ImtProof memory absence = _realTimeoutBeginProof(
            CHAIN_A,
            uint256(keccak256("value absent from the tree")),
            uint256(DEADLINE) + 1
        );
        uint256 predecessor = _predecessorIndexOf(present);
        absence.leaf = tree.leafAt(predecessor);
        absence.imtLeafIndex = predecessor;
        absence.imtProof = tree.merklePath(predecessor);

        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, present, present));
        manager.authorizeRefund(AtomicFlow({flowId: flowId, preimage: preimage}), 1, absence);
        assertEq(uint256(manager.legState(flowId, leg)), uint256(LegState.Committed), "leg still committed");
    }

    /// @notice A swap chain that sent its leg but never accepted the incoming one inserted no participation
    /// value; the peer's missing participation refunds its committed leg.
    /// @dev The peer's value, not this chain's own: the proof builder only plays remote chains.
    function test_authorizeRefund_Swap_RefundsCommittedLegWithoutParticipation() public {
        (bytes memory bundleBytes, bytes32 outgoing) = _bundleTo(CHAIN_A);
        bytes32 incoming = keccak256("swap incoming never accepted");
        AtomicFlowPreimage memory preimage = _swapPreimage(outgoing, incoming, CHAIN_A);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);
        uint256 leavesBefore = canonicalTree.leafCount();
        _appendAsCenter(outgoing, CHAIN_A, preimage);
        assertEq(canonicalTree.leafCount(), leavesBefore, "no participation without the incoming acceptance");

        uint256 peerIndex = preimage.legChainIds[0] == CHAIN_A ? 0 : 1;
        ImtProof memory absence = _realTimeoutBeginProof(
            CHAIN_A,
            _participationValue(flowId, CHAIN_A),
            uint256(DEADLINE) + 1
        );

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowRefundAuthorized(flowId, outgoing);
        manager.authorizeRefund(AtomicFlow({flowId: flowId, preimage: preimage}), peerIndex, absence);
        assertEq(uint256(manager.legState(flowId, outgoing)), uint256(LegState.Revertable), "leg revertable");

        manager.claimRefund(flowId, bundleBytes);
        assertEq(uint256(manager.legState(flowId, outgoing)), uint256(LegState.Reverted), "leg reverted");
    }
}

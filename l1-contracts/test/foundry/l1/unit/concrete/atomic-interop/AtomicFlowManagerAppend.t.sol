// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {AtomicFlowFixtures, AtomicPredeployFixture} from "./AtomicFlowFixtures.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {
    AtomicFlowPreimage,
    LegState,
    ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY,
    ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED,
    MAX_ATOMIC_FLOW_LEGS
} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerBundleHashesNotSorted,
    ManagerBundleNotInFlow,
    ManagerCommittedLegDestinationChainMismatch,
    ManagerCommittedLegSourceChainMismatch,
    ManagerFlowDeadlinePassed,
    ManagerFlowPreimageVersionMismatch,
    ManagerLegAlreadyRecorded,
    ManagerLegChainIdsLengthMismatch,
    ManagerLegChainNotAllowed,
    ManagerLegDestinationChainIdsLengthMismatch,
    ManagerNotInteropCenter,
    ManagerSettlementLayerNotL1,
    ManagerTooManyLegs
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {DummyL2InteropRootStorage} from "contracts/dev-contracts/test/DummyL2InteropRootStorage.sol";
import {
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_ROOT_STORAGE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers `AtomicFlowManager.append` (see {IAtomicFlowManager.append}).
/// @dev The manager and commitment tree sit at their canonical predeploys (real `commitmentTree()`
/// wiring and appender ACL); the receive filter is stubbed and the root storage a dummy, feeding the
/// filter and deadline gates. The caller ACL is exercised by pranking the canonical InteropCenter.
contract AtomicFlowManagerAppendTest is AtomicPredeployFixture {
    uint256 internal constant L1_CHAIN_ID = 5;
    uint64 internal constant DEADLINE = 1_700_000_000;
    uint256 internal constant OTHER_CHAIN_ID = 777;
    uint256 internal constant NOT_ALLOWED_CHAIN_ID = 888;

    AtomicFlowManager internal manager;
    L2InteropCommitmentTree internal tree;
    DummyL2InteropRootStorage internal rootStorage;

    function setUp() public {
        (manager, tree) = _deployAtomicPredeploys(L1_CHAIN_ID, true);
        // `append`'s deadline-freshness gate reads the latest imported root timestamp from the canonical
        // root storage; the dummy mirrors the production tracking without the bootloader-only ACL.
        deployCodeTo("DummyL2InteropRootStorage.sol:DummyL2InteropRootStorage", L2_INTEROP_ROOT_STORAGE_ADDR);
        rootStorage = DummyL2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

        // The remote chain of every flow below passes the receive filter; the filter tests use another.
        _setLegChainAllowed(OTHER_CHAIN_ID, true);
        _setLegChainAllowed(NOT_ALLOWED_CHAIN_ID, false);
        _setLegChainAllowed(L1_CHAIN_ID, false);
    }

    /// @dev A swap with `OTHER_CHAIN_ID`: `_localLeg` from this chain to it, `_remoteLeg` back.
    function _twoLegPreimage(
        bytes32 _localLeg,
        bytes32 _remoteLeg
    ) internal view returns (AtomicFlowPreimage memory preimage) {
        (preimage, , ) = AtomicFlowFixtures.swapPreimage({
            _legA: _localLeg,
            _chainA: block.chainid,
            _legB: _remoteLeg,
            _chainB: OTHER_CHAIN_ID,
            _deadline: DEADLINE,
            _settlementLayerChainId: L1_CHAIN_ID
        });
    }

    /// @dev A single leg from this chain to `OTHER_CHAIN_ID`: committing it is this chain's only step.
    function _singleLegPreimage(bytes32 _leg) internal view returns (AtomicFlowPreimage memory preimage) {
        bytes32[] memory legs = new bytes32[](1);
        legs[0] = _leg;
        uint256[] memory sources = new uint256[](1);
        sources[0] = block.chainid;
        uint256[] memory destinations = new uint256[](1);
        destinations[0] = OTHER_CHAIN_ID;
        preimage = AtomicFlowFixtures.nLegPreimage(legs, sources, destinations, DEADLINE, L1_CHAIN_ID);
    }

    /// @dev Every leg these tests commit goes to `OTHER_CHAIN_ID`.
    function _appendAsInteropCenter(bytes32 _bundleHash, AtomicFlowPreimage memory _preimage) internal {
        _appendAsInteropCenterWithLowNullifier(_bundleHash, 0, _preimage);
    }

    function _appendAsInteropCenterWithLowNullifier(
        bytes32 _bundleHash,
        uint256 _lowNullifierIndex,
        AtomicFlowPreimage memory _preimage
    ) internal {
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(_bundleHash, OTHER_CHAIN_ID, _lowNullifierIndex, _preimage);
    }

    /// @notice Two flows' participation values are inserted in sequence and the tree links them in value
    /// order. Every other case inserts one value, so this is the only coverage of a second insert and relink.
    /// @dev NOT a test of `_lowNullifierIndex` forwarding: that argument is a hint that
    /// {IndexedMerkleTree.insert} walks forward from, so `insert(value, 0)` is an equivalent mutant.
    function test_append_SecondParticipationLinksBothValues() public {
        AtomicFlowPreimage memory preimageA = _singleLegPreimage(keccak256("nullifier leg A"));
        AtomicFlowPreimage memory preimageB = _singleLegPreimage(keccak256("nullifier leg B"));
        uint256 valueA = AtomicFlowFixtures.participationValue(AtomicFlowFixtures.flowId(preimageA), block.chainid);
        uint256 valueB = AtomicFlowFixtures.participationValue(AtomicFlowFixtures.flowId(preimageB), block.chainid);

        // Insert in value order: the smaller value brackets at the head, the larger at leaf 1.
        (AtomicFlowPreimage memory first, AtomicFlowPreimage memory second) = valueA < valueB
            ? (preimageA, preimageB)
            : (preimageB, preimageA);
        (uint256 smallerValue, uint256 largerValue) = valueA < valueB ? (valueA, valueB) : (valueB, valueA);

        _appendAsInteropCenterWithLowNullifier(first.legBundleHashes[0], 0, first);
        // Leaf 1 now holds the smaller value and is the larger value's predecessor, so that is the index
        // a caller would supply as the hint.
        _appendAsInteropCenterWithLowNullifier(second.legBundleHashes[0], 1, second);

        assertEq(tree.leafCount(), 3, "head leaf plus both participation values");
        assertEq(tree.leafAt(1).value, smallerValue, "first insert holds the smaller value");
        assertEq(tree.leafAt(2).value, largerValue, "second insert holds the larger value");
        // The second insert must splice itself in after the first: leaf 1 now points at leaf 2.
        assertEq(tree.leafAt(1).nextIndex, 2, "the smaller leaf must link to the larger one");
        assertEq(tree.leafAt(1).nextValue, largerValue, "the smaller leaf must carry the larger value");
        assertEq(
            uint256(manager.legState(AtomicFlowFixtures.flowId(second), second.legBundleHashes[0])),
            uint256(LegState.Committed),
            "the second flow's leg must be Committed"
        );
    }

    /// @notice Happy path: the leg flips `Unset -> Committed` under the recomputed `flowId`. Committing it is
    /// this chain's only step in the flow, so the same call inserts the chain's participation value (leaf 1,
    /// after the genesis-seeded head).
    function test_append_CommitsLegAndInsertsParticipation() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(localLeg);
        bytes32 flowId = AtomicFlowFixtures.flowId(preimage);

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowLegCommitted(flowId, localLeg);
        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowParticipated(flowId, DEADLINE, 1);
        _appendAsInteropCenter(localLeg, preimage);

        assertEq(uint256(manager.legState(flowId, localLeg)), uint256(LegState.Committed), "leg must be Committed");
        assertEq(tree.leafCount(), 2, "one value must be inserted after the seeded head leaf");
        assertEq(
            tree.leafAt(1).value,
            AtomicFlowFixtures.participationValue(flowId, block.chainid),
            "inserted leaf must hold the participation value, not a commit value"
        );
    }

    /// @notice In a swap this chain still has its incoming leg to accept, so committing the outgoing leg
    /// inserts nothing yet.
    function test_append_SwapLegInsertsNothingBeforeAcceptance() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));

        _appendAsInteropCenter(localLeg, preimage);

        assertEq(uint256(manager.legState(AtomicFlowFixtures.flowId(preimage), localLeg)), uint256(LegState.Committed));
        assertEq(tree.leafCount(), 1, "only the seeded head leaf");
    }

    /// @notice Pins the version literals: they are mirrored off-chain by hand in
    /// `test/anvil-interop/src/helpers/imt-engine-lib.ts`, so a bump must break something here.
    function test_atomicFlowPreimageVersions_arePinned() public pure {
        assertEq(ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY, bytes1(0x01), "source-only version literal must be pinned");
        assertEq(ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED, bytes1(0x02), "accepted version literal must be pinned");
    }

    /// @notice `append` rejects a preimage whose `version` the manager does not support (0x03 here),
    /// so it can never commit a leg. The error names the latest supported version.
    function test_append_RevertWhen_FlowPreimageVersionMismatch() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        bytes1 unknownVersion = 0x03;
        preimage.version = unknownVersion;

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerFlowPreimageVersionMismatch.selector,
                ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED,
                unknownVersion
            )
        );
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice Source-only flows sent before the upgrade stay finalizable and refundable, but `append` starts
    /// none: the error names the version new flows are sent in.
    function test_append_RevertWhen_SourceOnlyFlow() public {
        bytes32 localLeg = keccak256("local leg");
        bytes32[] memory legs = new bytes32[](1);
        legs[0] = localLeg;
        uint256[] memory chains = new uint256[](1);
        chains[0] = block.chainid;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.sourceOnlyPreimage(legs, chains, DEADLINE, L1_CHAIN_ID);

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerFlowPreimageVersionMismatch.selector,
                ATOMIC_FLOW_PREIMAGE_VERSION_ACCEPTED,
                ATOMIC_FLOW_PREIMAGE_VERSION_SOURCE_ONLY
            )
        );
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice Footgun regression: a preimage not containing the committing bundle's hash is rejected —
    /// committing under such a `flowId` would be unfinalizable and unrefundable (funds stuck forever).
    function test_append_RevertWhen_CommittingBundleNotInFlow() public {
        AtomicFlowPreimage memory preimage = _twoLegPreimage(keccak256("local leg"), keccak256("remote leg"));
        bytes32 strayBundleHash = keccak256("stale off-chain prediction");

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerBundleNotInFlow.selector,
                AtomicFlowFixtures.flowId(preimage),
                strayBundleHash
            )
        );
        _appendAsInteropCenter(strayBundleHash, preimage);
    }

    /// @notice The committing bundle is in the preimage, but its aligned source chain id is not this
    /// chain. Such a leg's inclusion/absence proofs would target the wrong chain, so it is rejected.
    function test_append_RevertWhen_LegSourceChainMismatch() public {
        bytes32 remoteLeg = keccak256("remote leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(keccak256("local leg"), remoteLeg);

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerCommittedLegSourceChainMismatch.selector,
                AtomicFlowFixtures.flowId(preimage),
                block.chainid,
                OTHER_CHAIN_ID
            )
        );
        _appendAsInteropCenter(remoteLeg, preimage);
    }

    /// @notice A non-canonical preimage (leg hashes not strictly ascending) is rejected at send time:
    /// the finalize and refund paths canonicalize the same way and would never accept its `flowId`.
    function test_append_RevertWhen_BundleHashesNotSorted() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        // Swap the (ascending) leg hashes and their aligned chain ids to break canonical ordering.
        (preimage.legBundleHashes[0], preimage.legBundleHashes[1]) = (
            preimage.legBundleHashes[1],
            preimage.legBundleHashes[0]
        );
        (preimage.legChainIds[0], preimage.legChainIds[1]) = (preimage.legChainIds[1], preimage.legChainIds[0]);
        (preimage.legDestinationChainIds[0], preimage.legDestinationChainIds[1]) = (
            preimage.legDestinationChainIds[1],
            preimage.legDestinationChainIds[0]
        );

        vm.expectRevert(ManagerBundleHashesNotSorted.selector);
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice The canonical order is STRICTLY ascending: equal adjacent leg hashes (a duplicated
    /// leg) are rejected, not just descending ones. A duplicate would let one bundle occupy two leg
    /// slots — its single commit value would "prove" both, so a flow could finalize with fewer real
    /// commitments than legs.
    function test_append_RevertWhen_DuplicateLegBundleHashes() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        // Duplicate the first leg hash into the second slot (equal adjacent hashes).
        preimage.legBundleHashes[1] = preimage.legBundleHashes[0];

        vm.expectRevert(ManagerBundleHashesNotSorted.selector);
        _appendAsInteropCenter(preimage.legBundleHashes[0], preimage);
    }

    /// @notice A preimage must declare one source per leg; here the second leg has none.
    function test_append_RevertWhen_LegChainIdsLengthMismatch() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        uint256[] memory oneSource = new uint256[](1);
        oneSource[0] = preimage.legChainIds[0];
        preimage.legChainIds = oneSource;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainIdsLengthMismatch.selector, 2, 1));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice An accepted flow must declare one destination per leg; here it declares an extra one.
    function test_append_RevertWhen_LegDestinationChainIdsLengthMismatch() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        uint256[] memory threeDestinations = new uint256[](3);
        (threeDestinations[0], threeDestinations[1], threeDestinations[2]) = (
            preimage.legDestinationChainIds[0],
            preimage.legDestinationChainIds[1],
            OTHER_CHAIN_ID
        );
        preimage.legDestinationChainIds = threeDestinations;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegDestinationChainIdsLengthMismatch.selector, 2, 3));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice The leg's declared destination must be the bundle's: the destination's participation is what
    /// finality and the refund prove, so a wrong one fails at send instead of leaving a flow that can only
    /// time out.
    function test_append_RevertWhen_LegDestinationChainMismatch() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _singleLegPreimage(localLeg);
        preimage.legDestinationChainIds[0] = block.chainid;

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerCommittedLegDestinationChainMismatch.selector,
                AtomicFlowFixtures.flowId(preimage),
                OTHER_CHAIN_ID,
                block.chainid
            )
        );
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice A flow declaring a non-L1 settlement layer is rejected at send time: neither finalization
    /// nor refund proofs would ever accept it (both enforce SL == L1).
    function test_append_RevertWhen_SettlementLayerNotL1() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        preimage.settlementLayerChainId = L1_CHAIN_ID + 1;

        vm.expectRevert(abi.encodeWithSelector(ManagerSettlementLayerNotL1.selector, L1_CHAIN_ID, L1_CHAIN_ID + 1));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice A co-leg declaring a source chain this chain's receive filter rejects is refused: this chain
    /// could never prove that chain's participation or absence, stranding its burned leg.
    function test_append_RevertWhen_CoLegSourceChainNotAllowed() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        uint256 remoteIdx = preimage.legChainIds[0] == OTHER_CHAIN_ID ? 0 : 1;
        preimage.legChainIds[remoteIdx] = NOT_ALLOWED_CHAIN_ID;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotAllowed.selector, NOT_ALLOWED_CHAIN_ID));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice The filter covers the destinations too, including those of legs this chain does not send.
    function test_append_RevertWhen_CoLegDestinationChainNotAllowed() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        uint256 remoteIdx = preimage.legChainIds[0] == OTHER_CHAIN_ID ? 0 : 1;
        preimage.legDestinationChainIds[remoteIdx] = NOT_ALLOWED_CHAIN_ID;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotAllowed.selector, NOT_ALLOWED_CHAIN_ID));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice The filter scans EVERY leg, starting from the first: a rejected co-leg in slot 0 (ahead of
    /// the committing leg) is refused just like one in a later slot. Slot position is hash-order-dependent,
    /// so both arrangements must hold.
    function test_append_RevertWhen_FirstSlotCoLegNotAllowed() public {
        // Force the co-leg into slot 0: its hash sorts strictly below the local leg's.
        bytes32 coLeg = bytes32(uint256(1));
        bytes32 localLeg = keccak256("local leg");

        bytes32[] memory legs = new bytes32[](2);
        legs[0] = coLeg;
        legs[1] = localLeg;
        // The co-leg goes from the rejected chain to this one, the local leg from here to `OTHER_CHAIN_ID`.
        uint256[] memory sources = new uint256[](2);
        sources[0] = NOT_ALLOWED_CHAIN_ID;
        sources[1] = block.chainid;
        uint256[] memory destinations = new uint256[](2);
        destinations[0] = block.chainid;
        destinations[1] = OTHER_CHAIN_ID;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            sources,
            destinations,
            DEADLINE,
            L1_CHAIN_ID
        );

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotAllowed.selector, NOT_ALLOWED_CHAIN_ID));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice L1 as a declared co-leg source hits the same filter: bundles can never be initiated on L1
    /// and L1 is never an allowed interop peer, so an "L1 leg" is the unprovable-phantom-leg case.
    function test_append_RevertWhen_CoLegSourceChainIsL1() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        uint256 remoteIdx = preimage.legChainIds[0] == OTHER_CHAIN_ID ? 0 : 1;
        preimage.legChainIds[remoteIdx] = L1_CHAIN_ID;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegChainNotAllowed.selector, L1_CHAIN_ID));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice Entries naming this chain itself pass the filter without asking the Bridgehub: no peer entry
    /// is stubbed for `block.chainid`, so a lookup would revert.
    function test_append_LocalChainNeedsNoPeerEntry() public {
        bytes32 legA = keccak256("local leg A");
        bytes32 legB = keccak256("local leg B");
        bytes32[] memory legs = new bytes32[](2);
        (legs[0], legs[1]) = legA < legB ? (legA, legB) : (legB, legA);
        uint256[] memory sources = new uint256[](2);
        sources[0] = block.chainid;
        sources[1] = block.chainid;
        uint256[] memory destinations = new uint256[](2);
        destinations[0] = OTHER_CHAIN_ID;
        destinations[1] = OTHER_CHAIN_ID;
        AtomicFlowPreimage memory preimage = AtomicFlowFixtures.nLegPreimage(
            legs,
            sources,
            destinations,
            DEADLINE,
            L1_CHAIN_ID
        );

        _appendAsInteropCenter(legA, preimage);
        assertEq(
            uint256(manager.legState(AtomicFlowFixtures.flowId(preimage), legA)),
            uint256(LegState.Committed),
            "local leg must commit without a peer entry for this chain"
        );
    }

    /// @dev Imports a settlement-layer root with the given creation timestamp into the dummy root
    /// storage, bumping the tracked latest timestamp.
    function _importL1Root(uint256 _blockNumber, uint256 _timestamp) internal {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = keccak256(abi.encode("root", _blockNumber));
        rootStorage.addInteropRootWithTimestamp(L1_CHAIN_ID, _blockNumber, _timestamp, sides);
    }

    /// @notice Once a post-deadline settlement-layer root is imported, committing a new leg is
    /// rejected (see {AtomicFlowManager.append}).
    function test_append_RevertWhen_ImportedRootPostdatesDeadline() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        _importL1Root(100, DEADLINE + 1);

        vm.expectRevert(abi.encodeWithSelector(ManagerFlowDeadlinePassed.selector, DEADLINE, DEADLINE + 1));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice Boundary: a root created exactly AT the deadline does not expire the flow (the timeout
    /// proof requires a root created strictly after the deadline), so the leg still commits.
    function test_append_AllowedWhen_LatestImportedRootAtDeadline() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        _importL1Root(100, DEADLINE);

        _appendAsInteropCenter(localLeg, preimage);

        assertEq(uint256(manager.legState(AtomicFlowFixtures.flowId(preimage), localLeg)), uint256(LegState.Committed));
    }

    /// @notice The deadline gate keys on the flow's settlement layer only: a late root imported for some
    /// other chain says nothing about the SL clock and must not expire the flow.
    function test_append_IgnoresLateRootsOfOtherChains() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = keccak256("other chain root");
        rootStorage.addInteropRootWithTimestamp(OTHER_CHAIN_ID, 100, DEADLINE + 1, sides);

        _appendAsInteropCenter(localLeg, preimage);

        assertEq(uint256(manager.legState(AtomicFlowFixtures.flowId(preimage), localLeg)), uint256(LegState.Committed));
    }

    /// @dev Builds a preimage of `_legCount` legs from this chain to `OTHER_CHAIN_ID`, with strictly ascending
    /// leg hashes; returns the preimage and its lowest leg hash (a valid committing bundle).
    function _manyLegPreimage(
        uint256 _legCount
    ) internal view returns (AtomicFlowPreimage memory preimage, bytes32 firstLeg) {
        bytes32[] memory legs = new bytes32[](_legCount);
        uint256[] memory sources = new uint256[](_legCount);
        uint256[] memory destinations = new uint256[](_legCount);
        for (uint256 i = 0; i < _legCount; ++i) {
            // Strictly ascending by construction.
            legs[i] = bytes32(i + 1);
            sources[i] = block.chainid;
            destinations[i] = OTHER_CHAIN_ID;
        }
        preimage = AtomicFlowFixtures.nLegPreimage(legs, sources, destinations, DEADLINE, L1_CHAIN_ID);
        firstLeg = legs[0];
    }

    /// @notice A flow with more than {MAX_ATOMIC_FLOW_LEGS} legs cannot be committed.
    function test_append_RevertWhen_TooManyLegs() public {
        (AtomicFlowPreimage memory preimage, bytes32 firstLeg) = _manyLegPreimage(MAX_ATOMIC_FLOW_LEGS + 1);

        vm.expectRevert(
            abi.encodeWithSelector(ManagerTooManyLegs.selector, MAX_ATOMIC_FLOW_LEGS, MAX_ATOMIC_FLOW_LEGS + 1)
        );
        _appendAsInteropCenter(firstLeg, preimage);
    }

    /// @notice Boundary: a flow with exactly {MAX_ATOMIC_FLOW_LEGS} legs commits fine.
    function test_append_AllowsMaxLegs() public {
        (AtomicFlowPreimage memory preimage, bytes32 firstLeg) = _manyLegPreimage(MAX_ATOMIC_FLOW_LEGS);

        _appendAsInteropCenter(firstLeg, preimage);

        assertEq(uint256(manager.legState(AtomicFlowFixtures.flowId(preimage), firstLeg)), uint256(LegState.Committed));
    }

    /// @notice A `(flowId, bundleHash)` leg can only be committed once.
    function test_append_RevertWhen_LegAlreadyCommitted() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        _appendAsInteropCenter(localLeg, preimage);

        vm.expectRevert(
            abi.encodeWithSelector(
                ManagerLegAlreadyRecorded.selector,
                AtomicFlowFixtures.flowId(preimage),
                localLeg,
                LegState.Committed
            )
        );
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice `append` is callable only by the canonical InteropCenter.
    function test_append_RevertWhen_NotInteropCenter() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));

        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropCenter.selector, address(this)));
        manager.append(localLeg, OTHER_CHAIN_ID, 0, preimage);
    }
}

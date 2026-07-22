// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicFlowManager} from "contracts/atomic-interop/IAtomicFlowManager.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {AtomicFlowPreimage, LegState, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {
    ManagerBundleHashesNotSorted,
    ManagerCommittedBundleNotInFlow,
    ManagerCommittedLegSourceChainMismatch,
    ManagerLegAlreadyCommitted,
    ManagerLegSourceChainIdsLengthMismatch,
    ManagerLegSourceChainNotRegistered,
    ManagerNotInteropCenter,
    ManagerSettlementLayerNotL1
} from "contracts/atomic-interop/AtomicInteropErrors.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_BRIDGEHUB_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    L2_INTEROP_CENTER_ADDR,
    L2_INTEROP_COMMITMENT_TREE_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @dev Minimal Bridgehub stand-in exposing only the `baseTokenAssetId` registry mapping the manager
/// consults, deployed at the canonical `L2_BRIDGEHUB_ADDR`. A real Bridgehub needs the full ecosystem
/// bootstrap, which is irrelevant to `append`'s registration gate — the mock deliberately isolates
/// exactly the registry surface under test.
contract MockBridgehubRegistry {
    mapping(uint256 chainId => bytes32 assetId) public baseTokenAssetId;

    function setBaseTokenAssetId(uint256 _chainId, bytes32 _assetId) external {
        baseTokenAssetId[_chainId] = _assetId;
    }
}

/// @notice Covers `AtomicFlowManager.append`, which now receives the full `flowId` preimage instead of
/// an opaque, sender-supplied `flowId`. The load-bearing property under test: a bundle can only ever be
/// committed under a `flowId` whose preimage contains the bundle's own hash (with this chain declared as
/// the leg's source), so a wrong or stale preimage reverts the send instead of stranding the burned funds
/// in a leg that could neither finalize nor be refunded.
///
/// The manager and the commitment tree are deployed at their canonical predeploy addresses, so `append`
/// exercises the real `commitmentTree()` wiring and the tree's real appender ACL — no mocks. The caller
/// ACL is exercised by pranking the canonical InteropCenter address.
contract AtomicFlowManagerAppendTest is Test {
    uint256 internal constant L1_CHAIN_ID = 5;
    uint64 internal constant DEADLINE = 1_700_000_000;
    uint256 internal constant OTHER_CHAIN_ID = 777;

    AtomicFlowManager internal manager;
    L2InteropCommitmentTree internal tree;

    function setUp() public {
        deployCodeTo("AtomicFlowManager.sol:AtomicFlowManager", L2_ATOMIC_FLOW_MANAGER_ADDR);
        deployCodeTo("L2InteropCommitmentTree.sol:L2InteropCommitmentTree", L2_INTEROP_COMMITMENT_TREE_ADDR);
        deployCodeTo("AtomicFlowManagerAppend.t.sol:MockBridgehubRegistry", L2_BRIDGEHUB_ADDR);
        manager = AtomicFlowManager(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree = L2InteropCommitmentTree(L2_INTEROP_COMMITMENT_TREE_ADDR);

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        manager.initL2(L1_CHAIN_ID);
        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();

        // The canonical remote chain used by `_twoLegPreimage` is interop-registered; tests for the
        // registration gate use other, unregistered chain ids.
        MockBridgehubRegistry(L2_BRIDGEHUB_ADDR).setBaseTokenAssetId(OTHER_CHAIN_ID, keccak256("remote asset id"));
    }

    /// @dev A canonical two-leg preimage: `_localLeg` declared with this chain as source, `_remoteLeg`
    /// with `OTHER_CHAIN_ID`. Legs are returned in strictly ascending bundle-hash order with the source
    /// chain ids positionally aligned.
    function _twoLegPreimage(
        bytes32 _localLeg,
        bytes32 _remoteLeg
    ) internal view returns (AtomicFlowPreimage memory preimage) {
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = L1_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legSourceChainIds = new uint256[](2);
        (uint256 localIndex, uint256 remoteIndex) = _localLeg < _remoteLeg ? (0, 1) : (1, 0);
        preimage.legBundleHashes[localIndex] = _localLeg;
        preimage.legBundleHashes[remoteIndex] = _remoteLeg;
        preimage.legSourceChainIds[localIndex] = block.chainid;
        preimage.legSourceChainIds[remoteIndex] = OTHER_CHAIN_ID;
    }

    /// @dev Mirrors `AtomicFlowManager._validateAndComputeFlowId`'s hash (without the shape checks).
    function _flowId(AtomicFlowPreimage memory _preimage) internal pure returns (bytes32) {
        return keccak256(abi.encode(_preimage));
    }

    /// @dev Mirrors `AtomicInteropProof.commitValue`.
    function _commitValue(bytes32 _flowIdValue, bytes32 _bundleHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowIdValue, _bundleHash)));
    }

    function _appendAsInteropCenter(bytes32 _bundleHash, AtomicFlowPreimage memory _preimage) internal {
        vm.prank(L2_INTEROP_CENTER_ADDR);
        manager.append(_bundleHash, 0, _preimage);
    }

    /// @notice Happy path: the committing bundle is a leg of the supplied preimage with this chain as its
    /// declared source. The leg flips `Unset -> Committed` under the recomputed `flowId` and the leg's
    /// commit value lands in the commitment tree (leaf 1, after the genesis-seeded head).
    function test_append_CommitsLegAndInsertsCommitValue() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        bytes32 flowId = _flowId(preimage);

        vm.expectEmit(true, true, true, true, address(manager));
        emit IAtomicFlowManager.FlowCommitted(flowId, localLeg, DEADLINE, 1);
        _appendAsInteropCenter(localLeg, preimage);

        assertEq(uint256(manager.legState(flowId, localLeg)), uint256(LegState.Committed), "leg must be Committed");
        assertEq(tree.leafCount(), 2, "commit value must be inserted after the seeded head leaf");
        assertEq(tree.leafAt(1).value, _commitValue(flowId, localLeg), "inserted leaf must hold the commit value");
    }

    /// @notice The footgun regression: a preimage that does not contain the committing bundle's hash is
    /// rejected outright. Before this check the leg would have been committed under a `flowId` that does
    /// not contain it — unfinalizable and unrefundable, i.e. the burned funds stuck forever.
    function test_append_RevertWhen_CommittingBundleNotInFlow() public {
        AtomicFlowPreimage memory preimage = _twoLegPreimage(keccak256("local leg"), keccak256("remote leg"));
        bytes32 strayBundleHash = keccak256("stale off-chain prediction");

        vm.expectRevert(
            abi.encodeWithSelector(ManagerCommittedBundleNotInFlow.selector, _flowId(preimage), strayBundleHash)
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
                _flowId(preimage),
                block.chainid,
                OTHER_CHAIN_ID
            )
        );
        _appendAsInteropCenter(remoteLeg, preimage);
    }

    /// @notice A non-canonical preimage (leg hashes not strictly ascending) is rejected at send time.
    /// Committing under it would strand the leg: the finalize and refund paths canonicalize the same way
    /// and would never accept the resulting `flowId`.
    function test_append_RevertWhen_BundleHashesNotSorted() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        // Swap the (ascending) leg hashes and their aligned chain ids to break canonical ordering.
        (preimage.legBundleHashes[0], preimage.legBundleHashes[1]) = (
            preimage.legBundleHashes[1],
            preimage.legBundleHashes[0]
        );
        (preimage.legSourceChainIds[0], preimage.legSourceChainIds[1]) = (
            preimage.legSourceChainIds[1],
            preimage.legSourceChainIds[0]
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
        preimage.legSourceChainIds[0] = block.chainid;
        preimage.legSourceChainIds[1] = block.chainid;

        vm.expectRevert(ManagerBundleHashesNotSorted.selector);
        _appendAsInteropCenter(preimage.legBundleHashes[0], preimage);
    }

    /// @notice A preimage whose source-chain-id array is not aligned 1:1 with the leg hashes is rejected.
    function test_append_RevertWhen_SourceChainIdsLengthMismatch() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        preimage.legSourceChainIds = new uint256[](1);
        preimage.legSourceChainIds[0] = block.chainid;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegSourceChainIdsLengthMismatch.selector, 2, 1));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice A flow declaring a non-L1 settlement layer is rejected at send time: neither finalization
    /// nor refund proofs would ever accept it (both enforce SL == L1), so committing it would strand the
    /// burned funds.
    function test_append_RevertWhen_SettlementLayerNotL1() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        preimage.settlementLayerChainId = L1_CHAIN_ID + 1;

        vm.expectRevert(abi.encodeWithSelector(ManagerSettlementLayerNotL1.selector, L1_CHAIN_ID, L1_CHAIN_ID + 1));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice A co-leg declaring a source chain the Bridgehub does not know is rejected: such a leg
    /// could never be proven committed OR absent (no MessageRoot presence to prove against), so
    /// committing alongside it would strand this chain's burned leg with neither finalization nor
    /// refund possible.
    function test_append_RevertWhen_CoLegSourceChainNotRegistered() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        uint256 unregisteredChainId = 888;
        // Redeclare the remote leg's source as a chain id absent from the Bridgehub registry.
        for (uint256 i = 0; i < preimage.legSourceChainIds.length; ++i) {
            if (preimage.legSourceChainIds[i] == OTHER_CHAIN_ID) {
                preimage.legSourceChainIds[i] = unregisteredChainId;
            }
        }

        vm.expectRevert(abi.encodeWithSelector(ManagerLegSourceChainNotRegistered.selector, unregisteredChainId));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice The registration gate scans EVERY leg, starting from the first: an unregistered
    /// co-leg in slot 0 (ahead of the committing leg) is rejected just like one in a later slot.
    /// Slot position is hash-order-dependent, so both arrangements must hold.
    function test_append_RevertWhen_FirstSlotCoLegUnregistered() public {
        // Force the (unregistered) co-leg into slot 0: its hash sorts strictly below the local leg's.
        bytes32 coLeg = bytes32(uint256(1));
        bytes32 localLeg = keccak256("local leg");
        uint256 unregisteredChainId = 888;

        AtomicFlowPreimage memory preimage;
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = L1_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legBundleHashes[0] = coLeg;
        preimage.legBundleHashes[1] = localLeg;
        preimage.legSourceChainIds = new uint256[](2);
        preimage.legSourceChainIds[0] = unregisteredChainId;
        preimage.legSourceChainIds[1] = block.chainid;

        vm.expectRevert(abi.encodeWithSelector(ManagerLegSourceChainNotRegistered.selector, unregisteredChainId));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice L1 as a declared co-leg source is rejected via the same registration gate: interop
    /// bundles can never be initiated on L1, and L1 is never registered as an interop chain in the L2
    /// Bridgehub, so an "L1 leg" is exactly the unprovable-phantom-leg case.
    function test_append_RevertWhen_CoLegSourceChainIsL1() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        for (uint256 i = 0; i < preimage.legSourceChainIds.length; ++i) {
            if (preimage.legSourceChainIds[i] == OTHER_CHAIN_ID) {
                preimage.legSourceChainIds[i] = L1_CHAIN_ID;
            }
        }

        vm.expectRevert(abi.encodeWithSelector(ManagerLegSourceChainNotRegistered.selector, L1_CHAIN_ID));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice Legs declaring this chain itself never consult the Bridgehub registry: an all-local
    /// flow commits fine even though `block.chainid` has no registry entry (this chain's legs are
    /// validated by the coupling check instead).
    function test_append_AllLocalLegsNeedNoRegistration() public {
        bytes32 legA = keccak256("local leg A");
        bytes32 legB = keccak256("local leg B");
        AtomicFlowPreimage memory preimage;
        preimage.deadline = DEADLINE;
        preimage.settlementLayerChainId = L1_CHAIN_ID;
        preimage.legBundleHashes = new bytes32[](2);
        preimage.legSourceChainIds = new uint256[](2);
        (preimage.legBundleHashes[0], preimage.legBundleHashes[1]) = legA < legB ? (legA, legB) : (legB, legA);
        preimage.legSourceChainIds[0] = block.chainid;
        preimage.legSourceChainIds[1] = block.chainid;

        _appendAsInteropCenter(legA, preimage);
        assertEq(
            uint256(manager.legState(_flowId(preimage), legA)),
            uint256(LegState.Committed),
            "all-local leg must commit without any registry entry"
        );
    }

    /// @notice A `(flowId, bundleHash)` leg can only be committed once.
    function test_append_RevertWhen_LegAlreadyCommitted() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));
        _appendAsInteropCenter(localLeg, preimage);

        vm.expectRevert(abi.encodeWithSelector(ManagerLegAlreadyCommitted.selector, _flowId(preimage), localLeg));
        _appendAsInteropCenter(localLeg, preimage);
    }

    /// @notice `append` is callable only by the canonical InteropCenter.
    function test_append_RevertWhen_NotInteropCenter() public {
        bytes32 localLeg = keccak256("local leg");
        AtomicFlowPreimage memory preimage = _twoLegPreimage(localLeg, keccak256("remote leg"));

        vm.expectRevert(abi.encodeWithSelector(ManagerNotInteropCenter.selector, address(this)));
        manager.append(localLeg, 0, preimage);
    }
}

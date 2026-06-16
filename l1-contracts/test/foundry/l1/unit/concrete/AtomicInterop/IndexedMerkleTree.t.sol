// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {
    IndexedMerkleTreeLib,
    IMT,
    IMTLeaf,
    IMT_DEPTH,
    IMTAlreadyInitialized,
    IMTValueZero,
    IMTValueAlreadyExists,
    IMTLowLeafValueTooLarge,
    IMTLowLeafNextTooSmall,
    IMTProofWrongLength
} from "contracts/common/libraries/IndexedMerkleTree.sol";

/// @notice Tiny harness exposing the internal {IndexedMerkleTreeLib} functions over a single `IMT`
/// storage var, so the engine can be unit tested directly (the lib funcs are `internal`).
contract IMTHarness {
    using IndexedMerkleTreeLib for IMT;

    IMT internal _imt;

    function setup() external {
        _imt.setup();
    }

    function insert(uint256 _value, uint256 _lowLeafIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        return _imt.insert(_value, _lowLeafIndex);
    }

    function root() external view returns (bytes32) {
        return _imt.root();
    }

    function leafCount() external view returns (uint256) {
        return _imt.leafCount;
    }

    function leafAt(uint256 _index) external view returns (IMTLeaf memory) {
        return _imt.leaves[_index];
    }

    function merklePath(uint256 _index) external view returns (bytes32[] memory) {
        return _imt.merklePath(_index);
    }

    function verifyInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _leaf,
        uint256 _leafIndex,
        bytes32[] memory _proof
    ) external pure returns (bool) {
        return IndexedMerkleTreeLib.verifyInclusion(_root, _value, _leaf, _leafIndex, _proof);
    }

    function verifyNonInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _lowLeaf,
        uint256 _lowLeafIndex,
        bytes32[] memory _lowLeafProof
    ) external pure returns (bool) {
        return IndexedMerkleTreeLib.verifyNonInclusion(_root, _value, _lowLeaf, _lowLeafIndex, _lowLeafProof);
    }
}

/// @notice Direct unit tests for the shared fixed-depth Indexed Merkle Tree engine
/// ({IndexedMerkleTreeLib}): setup, sorted-linked-list maintenance on insert, value/low-leaf
/// validation, and content-addressed inclusion / non-inclusion verification.
contract IndexedMerkleTreeTest is Test {
    IMTHarness internal imt;

    function setUp() public {
        imt = new IMTHarness();
        imt.setup();
    }

    // ── setup ─────────────────────────────────────────────────────────────────────────────

    function test_setup_seedsHeadLeafOnce() public {
        // The sentinel `{0,0,0}` head leaf occupies index 0.
        assertEq(imt.leafCount(), 1, "head leaf seeded");
        IMTLeaf memory head = imt.leafAt(0);
        assertEq(head.value, 0);
        assertEq(head.nextIndex, 0);
        assertEq(head.nextValue, 0);
    }

    function test_setup_revertsOnDoubleSetup() public {
        vm.expectRevert(IMTAlreadyInitialized.selector);
        imt.setup();
    }

    // ── insert / sorted linked list ─────────────────────────────────────────────────────────

    function test_insert_maintainsSortedLinkedList() public {
        imt.insert(100, 0); // head -> 100 @ idx 1
        imt.insert(300, 1); // 100 -> 300 @ idx 2
        imt.insert(200, 1); // 100 -> 200 @ idx 3 -> 300 (spliced between)

        assertEq(imt.leafCount(), 4);

        // head{0, nextIndex:1, nextValue:100}
        IMTLeaf memory head = imt.leafAt(0);
        assertEq(head.value, 0);
        assertEq(head.nextIndex, 1);
        assertEq(head.nextValue, 100);

        // leaf1 (value 100) now points to 200 at index 3
        IMTLeaf memory l1 = imt.leafAt(1);
        assertEq(l1.value, 100);
        assertEq(l1.nextIndex, 3);
        assertEq(l1.nextValue, 200);

        // leaf3 (value 200) points to 300 at index 2
        IMTLeaf memory l3 = imt.leafAt(3);
        assertEq(l3.value, 200);
        assertEq(l3.nextIndex, 2);
        assertEq(l3.nextValue, 300);

        // leaf2 (value 300) is the max — tail of the list
        IMTLeaf memory l2 = imt.leafAt(2);
        assertEq(l2.value, 300);
        assertEq(l2.nextIndex, 0);
        assertEq(l2.nextValue, 0);
    }

    function test_insert_returnsAdvancingIndexAndRootChanges() public {
        bytes32 seedRoot = imt.root();
        (uint256 idx1, bytes32 root1) = imt.insert(100, 0);
        (uint256 idx2, bytes32 root2) = imt.insert(200, 1);

        assertEq(idx1, 1, "first inserted leaf at index 1");
        assertEq(idx2, 2, "second inserted leaf at index 2");
        assertTrue(root1 != seedRoot, "root changes after first insert");
        assertTrue(root2 != root1, "root changes after second insert");
        assertEq(imt.root(), root2, "stored root tracks last insert");
    }

    // ── insert validation ───────────────────────────────────────────────────────────────────

    function test_insert_revertsOnZeroValue() public {
        vm.expectRevert(IMTValueZero.selector);
        imt.insert(0, 0);
    }

    function test_insert_revertsOnDuplicateValue() public {
        imt.insert(100, 0);
        vm.expectRevert(abi.encodeWithSelector(IMTValueAlreadyExists.selector, uint256(100)));
        imt.insert(100, 1);
    }

    function test_insert_revertsWhenLowLeafValueTooLarge() public {
        imt.insert(100, 0); // head -> 100

        // 50 is below leaf1's value (100), so leaf1 cannot be its low-nullifier.
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafValueTooLarge.selector, uint256(100), uint256(50)));
        imt.insert(50, 1);
    }

    function test_insert_revertsWhenLowLeafNextTooSmall() public {
        imt.insert(100, 0); // head -> 100, head.nextValue == 100

        // 150's true low-nullifier is leaf1 (100), not the head: head.nextValue (100) <= 150.
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, uint256(100), uint256(150)));
        imt.insert(150, 0);
    }

    // ── inclusion verification ───────────────────────────────────────────────────────────────

    function test_verifyInclusion_roundTripsForPresentValue() public {
        imt.insert(100, 0);
        imt.insert(300, 1);
        imt.insert(200, 1);

        uint256 idx = 3; // value 200
        IMTLeaf memory leaf = imt.leafAt(idx);
        bytes32[] memory proof = imt.merklePath(idx);

        assertTrue(
            imt.verifyInclusion(imt.root(), 200, leaf, idx, proof),
            "present value verifies inclusion"
        );
    }

    function test_verifyInclusion_falseForWrongValue() public {
        imt.insert(100, 0);
        imt.insert(200, 1);

        uint256 idx = 1; // value 100
        IMTLeaf memory leaf = imt.leafAt(idx);
        bytes32[] memory proof = imt.merklePath(idx);

        // The leaf's value (100) does not match the queried value (999) -> not included.
        assertFalse(imt.verifyInclusion(imt.root(), 999, leaf, idx, proof), "wrong value rejected");
    }

    function test_verifyInclusion_falseForWrongLeafIndex() public {
        imt.insert(100, 0);
        imt.insert(200, 1);

        uint256 idx = 1; // value 100
        IMTLeaf memory leaf = imt.leafAt(idx);
        // Build the proof for a different index so it cannot hash up to the root at `idx`.
        bytes32[] memory wrongProof = imt.merklePath(2);

        assertFalse(imt.verifyInclusion(imt.root(), 100, leaf, idx, wrongProof), "wrong proof rejected");
    }

    function test_verifyInclusion_revertsOnWrongProofLength() public {
        imt.insert(100, 0);
        IMTLeaf memory leaf = imt.leafAt(1);
        bytes32 currentRoot = imt.root();
        bytes32[] memory shortProof = new bytes32[](IMT_DEPTH - 1);

        vm.expectRevert(
            abi.encodeWithSelector(IMTProofWrongLength.selector, IMT_DEPTH, IMT_DEPTH - 1)
        );
        imt.verifyInclusion(currentRoot, 100, leaf, 1, shortProof);
    }

    // ── non-inclusion verification ───────────────────────────────────────────────────────────

    function test_verifyNonInclusion_trueForAbsentValueWithCorrectLowNullifier() public {
        imt.insert(100, 0);
        imt.insert(300, 1);
        imt.insert(200, 1);

        // 250 is absent; its low-nullifier is leaf3 (value 200, next 300) which brackets it.
        uint256 lowIdx = 3;
        IMTLeaf memory lowLeaf = imt.leafAt(lowIdx);
        bytes32[] memory proof = imt.merklePath(lowIdx);

        assertTrue(
            imt.verifyNonInclusion(imt.root(), 250, lowLeaf, lowIdx, proof),
            "absent value with correct low-nullifier verifies non-inclusion"
        );
    }

    function test_verifyNonInclusion_trueForValueAboveTailViaHead() public {
        imt.insert(100, 0); // head -> 100 (tail)

        // 400 is above the tail (100, next 0). The tail leaf1 brackets everything above it.
        IMTLeaf memory tail = imt.leafAt(1);
        bytes32[] memory proof = imt.merklePath(1);
        assertTrue(imt.verifyNonInclusion(imt.root(), 400, tail, 1, proof), "above-tail non-inclusion verifies");
    }

    function test_verifyNonInclusion_falseWhenLowLeafDoesNotBracket() public {
        imt.insert(100, 0);
        imt.insert(300, 1);
        imt.insert(200, 1);

        // 250 is absent but we exhibit the WRONG low-nullifier (leaf1: value 100, next 200) — its
        // interval (100, 200) does not bracket 250, so non-inclusion fails.
        uint256 wrongLowIdx = 1;
        IMTLeaf memory wrongLow = imt.leafAt(wrongLowIdx);
        bytes32[] memory proof = imt.merklePath(wrongLowIdx);

        assertFalse(
            imt.verifyNonInclusion(imt.root(), 250, wrongLow, wrongLowIdx, proof),
            "non-bracketing low-nullifier rejected"
        );
    }

    function test_verifyNonInclusion_falseForPresentValue() public {
        imt.insert(100, 0);
        imt.insert(200, 1);

        // 200 IS present; claiming non-inclusion with leaf1 (100, next 200) must fail because its
        // next value equals the queried value.
        IMTLeaf memory low = imt.leafAt(1);
        bytes32[] memory proof = imt.merklePath(1);
        assertFalse(imt.verifyNonInclusion(imt.root(), 200, low, 1, proof), "present value not absent");
    }

    function test_verifyNonInclusion_revertsOnWrongProofLength() public {
        imt.insert(100, 0);
        IMTLeaf memory low = imt.leafAt(1);
        bytes32 currentRoot = imt.root();
        bytes32[] memory longProof = new bytes32[](IMT_DEPTH + 1);

        vm.expectRevert(
            abi.encodeWithSelector(IMTProofWrongLength.selector, IMT_DEPTH, IMT_DEPTH + 1)
        );
        imt.verifyNonInclusion(currentRoot, 400, low, 1, longProof);
    }
}

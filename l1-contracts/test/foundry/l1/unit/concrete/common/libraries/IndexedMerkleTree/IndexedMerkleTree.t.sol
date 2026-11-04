// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IMT_EMPTY_LEAF_HASH} from "contracts/common/Config.sol";
import {
    IMTAlreadyInitialized,
    IMTLeafValueMismatch,
    IMTLowLeafIndexOutOfBounds,
    IMTLowLeafNextTooSmall,
    IMTLowLeafValueTooLarge,
    IMTNotInitialized,
    IMTValueAlreadyExists,
    IMTValueZero
} from "contracts/common/L1ContractErrors.sol";
import {IMT, IMTLeaf, IndexedMerkleTree} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {Merkle} from "contracts/common/libraries/Merkle.sol";

contract IndexedMerkleTreeHarness {
    using IndexedMerkleTree for IMT;

    IMT internal tree;

    function setup() external {
        tree.setup();
    }

    function insert(uint256 _value, uint256 _lowLeafIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        return tree.insert(_value, _lowLeafIndex);
    }

    function root() external view returns (bytes32) {
        return tree.root();
    }

    function merklePath(uint256 _leafIndex) external view returns (bytes32[] memory) {
        return tree.merklePath(_leafIndex);
    }

    function leaf(uint256 _leafIndex) external view returns (IMTLeaf memory) {
        return tree.leaves[_leafIndex];
    }

    function leafCount() external view returns (uint256) {
        return tree.tree._leafNumber;
    }

    function valueToIndex(uint256 _value) external view returns (uint256) {
        return tree.valueToIndex[_value];
    }

    function verifyInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _leaf,
        uint256 _leafIndex,
        bytes32[] memory _proof
    ) external pure returns (bool) {
        return IndexedMerkleTree.verifyInclusion(_root, _value, _leaf, _leafIndex, _proof);
    }

    function verifyNonInclusion(
        bytes32 _root,
        uint256 _value,
        IMTLeaf memory _lowLeaf,
        uint256 _lowLeafIndex,
        bytes32[] memory _lowLeafProof
    ) external pure returns (bool) {
        return IndexedMerkleTree.verifyNonInclusion(_root, _value, _lowLeaf, _lowLeafIndex, _lowLeafProof);
    }

    function hashLeaf(IMTLeaf memory _leaf) external pure returns (bytes32) {
        return IndexedMerkleTree.hashLeaf(_leaf);
    }
}

contract IndexedMerkleTreeTest is Test {
    IndexedMerkleTreeHarness internal tree;

    function setUp() public {
        tree = new IndexedMerkleTreeHarness();
        tree.setup();
    }

    function test_SetupInitializesSentinelLeafAndRoot() public view {
        IMTLeaf memory sentinelLeaf = tree.leaf(0);
        bytes32 sentinelHash = tree.hashLeaf(sentinelLeaf);

        assertEq(sentinelLeaf.value, 0);
        assertEq(sentinelLeaf.nextIndex, 0);
        assertEq(sentinelLeaf.nextValue, 0);
        assertEq(tree.leafCount(), 1);
        assertEq(tree.root(), sentinelHash);
        assertEq(tree.merklePath(0).length, 0);
    }

    function test_RevertWhen_SetupCalledTwice() public {
        vm.expectRevert(IMTAlreadyInitialized.selector);
        tree.setup();
    }

    function test_RevertWhen_InsertBeforeSetup() public {
        IndexedMerkleTreeHarness uninitializedTree = new IndexedMerkleTreeHarness();

        vm.expectRevert(IMTNotInitialized.selector);
        uninitializedTree.insert(1, 0);
    }

    function test_RevertWhen_InsertZeroValue() public {
        vm.expectRevert(IMTValueZero.selector);
        tree.insert(0, 0);
    }

    function test_InsertUpdatesLinkedListAndRoot() public {
        (uint256 firstIndex, bytes32 firstRoot) = tree.insert(10, 0);
        (uint256 secondIndex, bytes32 secondRoot) = tree.insert(20, firstIndex);
        (uint256 thirdIndex, bytes32 thirdRoot) = tree.insert(15, firstIndex);

        assertEq(firstIndex, 1);
        assertEq(secondIndex, 2);
        assertEq(thirdIndex, 3);
        assertEq(tree.root(), thirdRoot);
        assertNotEq(firstRoot, secondRoot);
        assertNotEq(secondRoot, thirdRoot);
        assertEq(tree.leafCount(), 4);
        assertEq(tree.valueToIndex(10), firstIndex);
        assertEq(tree.valueToIndex(20), secondIndex);
        assertEq(tree.valueToIndex(15), thirdIndex);

        _assertLeaf(tree.leaf(0), 0, firstIndex, 10);
        _assertLeaf(tree.leaf(firstIndex), 10, thirdIndex, 15);
        _assertLeaf(tree.leaf(thirdIndex), 15, secondIndex, 20);
        _assertLeaf(tree.leaf(secondIndex), 20, 0, 0);
    }

    function test_RevertWhen_DuplicateValueInserted() public {
        tree.insert(10, 0);

        vm.expectRevert(abi.encodeWithSelector(IMTValueAlreadyExists.selector, 10));
        tree.insert(10, 0);
    }

    function test_RevertWhen_LowLeafIndexOutOfBounds() public {
        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafIndexOutOfBounds.selector, 1, 1));
        tree.insert(10, 1);
    }

    function test_RevertWhen_LowLeafValueIsTooLarge() public {
        (uint256 leafIndex, ) = tree.insert(10, 0);

        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafValueTooLarge.selector, 10, 5));
        tree.insert(5, leafIndex);
    }

    function test_InsertFindsUpdatedLowLeafWhenSuppliedLowLeafIsStale() public {
        (uint256 firstIndex, ) = tree.insert(10, 0);
        (uint256 secondIndex, ) = tree.insert(20, firstIndex);

        (uint256 thirdIndex, ) = tree.insert(15, 0);

        _assertLeaf(tree.leaf(0), 0, firstIndex, 10);
        _assertLeaf(tree.leaf(firstIndex), 10, thirdIndex, 15);
        _assertLeaf(tree.leaf(thirdIndex), 15, secondIndex, 20);
    }

    /// @notice Regression (audit): a stale-but-once-valid hint must never make `insert` revert with a
    /// hint-validity error, no matter how many later inserts land between the hinted low leaf and the
    /// new value — otherwise front-running inserts into that gap could grief the insert. See
    /// {protocol-docs/message-root.md#indexed-merkle-tree-indexedmerkletree}.
    function test_regression_insertSucceedsWithArbitrarilyStaleLowLeafHint() public {
        // The hint (index 0, the sentinel) is computed against an empty tree; many inserts then land
        // between the hinted low leaf and the new value before it is used.
        uint256 intermediateInserts = 50;
        uint256 lowLeafIndex = 0;
        for (uint256 i = 0; i < intermediateInserts; ++i) {
            (lowLeafIndex, ) = tree.insert((i + 1) * 10, lowLeafIndex);
        }

        uint256 newValue = (intermediateInserts + 1) * 10;
        (uint256 newIndex, bytes32 newRoot) = tree.insert(newValue, 0);

        // The walk found the true low leaf (the highest inserted value) and linked the new tail leaf.
        assertEq(tree.root(), newRoot);
        assertEq(tree.valueToIndex(newValue), newIndex);
        _assertLeaf(tree.leaf(lowLeafIndex), intermediateInserts * 10, newIndex, newValue);
        _assertLeaf(tree.leaf(newIndex), newValue, 0, 0);
    }

    function test_VerifyInclusion() public {
        (uint256 leafIndex, bytes32 root) = tree.insert(10, 0);
        IMTLeaf memory leaf = tree.leaf(leafIndex);
        bytes32[] memory proof = tree.merklePath(leafIndex);

        assertTrue(tree.verifyInclusion(root, 10, leaf, leafIndex, proof));
        assertEq(Merkle.calculateRootMemory(proof, leafIndex, tree.hashLeaf(leaf)), root);

        vm.expectRevert(abi.encodeWithSelector(IMTLeafValueMismatch.selector, 11, 10));
        tree.verifyInclusion(root, 11, leaf, leafIndex, proof);
    }

    function test_VerifyNonInclusionWithMiddleInterval() public {
        (uint256 firstIndex, ) = tree.insert(10, 0);
        tree.insert(20, firstIndex);
        bytes32 root = tree.root();
        IMTLeaf memory lowLeaf = tree.leaf(firstIndex);
        bytes32[] memory proof = tree.merklePath(firstIndex);

        assertTrue(tree.verifyNonInclusion(root, 15, lowLeaf, firstIndex, proof));
        assertFalse(tree.verifyNonInclusion(bytes32(uint256(1)), 15, lowLeaf, firstIndex, proof));

        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafValueTooLarge.selector, 10, 10));
        tree.verifyNonInclusion(root, 10, lowLeaf, firstIndex, proof);

        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafNextTooSmall.selector, 20, 20));
        tree.verifyNonInclusion(root, 20, lowLeaf, firstIndex, proof);
    }

    function test_VerifyNonInclusionWithTailInterval() public {
        (uint256 leafIndex, bytes32 root) = tree.insert(10, 0);
        IMTLeaf memory tailLeaf = tree.leaf(leafIndex);
        bytes32[] memory proof = tree.merklePath(leafIndex);

        assertTrue(tree.verifyNonInclusion(root, 100, tailLeaf, leafIndex, proof));

        vm.expectRevert(abi.encodeWithSelector(IMTLowLeafValueTooLarge.selector, 10, 5));
        tree.verifyNonInclusion(root, 5, tailLeaf, leafIndex, proof);

        vm.expectRevert(IMTValueZero.selector);
        tree.verifyNonInclusion(root, 0, tailLeaf, leafIndex, proof);
    }

    function test_MerklePathUsesCurrentFullMerkleHeight() public {
        assertEq(tree.merklePath(0).length, 0);

        (uint256 firstIndex, ) = tree.insert(10, 0);
        assertEq(tree.merklePath(0).length, 1);
        assertEq(tree.merklePath(firstIndex).length, 1);

        (uint256 secondIndex, ) = tree.insert(20, firstIndex);
        assertEq(tree.merklePath(secondIndex).length, 2);
    }

    /// @notice Regression: the empty-leaf padding (`IMT_EMPTY_LEAF_HASH`) must stay distinct from
    /// `hashLeaf({0,0,0})` — otherwise a padded slot would verify as a `{0,0,0}` tail low leaf and could
    /// prove a *present* value absent. See {protocol-docs/message-root.md#indexed-merkle-tree-indexedmerkletree}.
    function test_emptyLeafPaddingIsNotAValidLeafHash() public view {
        assertTrue(IMT_EMPTY_LEAF_HASH != tree.hashLeaf(IMTLeaf({value: 0, nextIndex: 0, nextValue: 0})));
    }

    function test_regression_paddedIndexCannotForgeNonInclusionOfPresentValue() public {
        // 3 leaves in a 4-slot tree, so index 3 is an unused padded slot.
        (uint256 firstIndex, ) = tree.insert(10, 0);
        (uint256 secondIndex, ) = tree.insert(20, firstIndex);
        assertEq(tree.leafCount(), 3);
        assertEq(secondIndex, 2);
        bytes32 root = tree.root();

        // Forge non-inclusion of the *present* value 20 via a `{0,0,0}` low leaf at padded index 3.
        // The getter refuses paths for padded indices, so the proof is hand-built from leaf 2's siblings.
        IMTLeaf memory forgedLowLeaf = IMTLeaf({value: 0, nextIndex: 0, nextValue: 0});
        uint256 paddedIndex = 3;
        bytes32[] memory forgedProof = new bytes32[](2);
        forgedProof[0] = tree.hashLeaf(tree.leaf(secondIndex)); // sibling leaf at index 2
        forgedProof[1] = tree.merklePath(secondIndex)[1]; // shared upper node (n0)
        assertFalse(
            tree.verifyNonInclusion(root, 20, forgedLowLeaf, paddedIndex, forgedProof),
            "padded {0,0,0} low leaf must not forge non-inclusion of a present value"
        );

        // Legit non-inclusion via a real low leaf still works.
        IMTLeaf memory realLowLeaf = tree.leaf(firstIndex); // {10, secondIndex, 20}
        assertTrue(tree.verifyNonInclusion(root, 15, realLowLeaf, firstIndex, tree.merklePath(firstIndex)));
    }

    function _assertLeaf(IMTLeaf memory _leaf, uint256 _value, uint256 _nextIndex, uint256 _nextValue) internal pure {
        assertEq(_leaf.value, _value);
        assertEq(_leaf.nextIndex, _nextIndex);
        assertEq(_leaf.nextValue, _nextValue);
    }
}

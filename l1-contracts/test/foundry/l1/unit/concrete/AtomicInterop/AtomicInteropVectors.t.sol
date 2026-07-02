// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test, console} from "forge-std/Test.sol";
import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {AtomicInteropProof} from "contracts/atomic-interop/libraries/AtomicInteropProof.sol";
import {InteropDataEncoding} from "contracts/interop/InteropDataEncoding.sol";
import {AtomicInteropTestUtils, TestL2InteropCommitmentTree} from "./AtomicInteropTestUtils.sol";

/// @notice Generates the golden values for the spec's worked-example appendix. Uses the REAL Solidity
/// encodings (abi.encode), the canonical bundleHash/commitValue, and the real IMT engine, so the vector
/// is reproducible. flowId here is the CORRECTED 4-field preimage (legBundleHashes, legSourceChainIds,
/// deadline, settlementLayerChainId) per the spec — not the current 3-field code.
contract AtomicInteropVectorsTest is Test {
    function test_emitGoldenVectors() public {
        AtomicInteropTestUtils.installSystemMocks();

        uint256 CHAIN_A = 271;
        uint256 CHAIN_B = 272;
        uint64 deadline = 2000;
        uint256 slChainId = 506;
        bytes memory bundleBytesA = hex"a1"; // illustrative leg-A bundle bytes
        bytes memory bundleBytesB = hex"b2"; // illustrative leg-B bundle bytes

        bytes32 hA = InteropDataEncoding.encodeInteropBundleHash(CHAIN_A, bundleBytesA);
        bytes32 hB = InteropDataEncoding.encodeInteropBundleHash(CHAIN_B, bundleBytesB);

        // sort (bundleHash, sourceChain) PAIRS by bundleHash
        bytes32[] memory legs = new bytes32[](2);
        uint256[] memory chains = new uint256[](2);
        if (hA < hB) {
            (legs[0], legs[1], chains[0], chains[1]) = (hA, hB, CHAIN_A, CHAIN_B);
        } else {
            (legs[0], legs[1], chains[0], chains[1]) = (hB, hA, CHAIN_B, CHAIN_A);
        }

        bytes32 flowId = keccak256(abi.encode(legs, chains, deadline, slChainId));
        uint256 cvA = AtomicInteropProof.commitValue(flowId, hA);

        // IMT: empty (seed) root, then root after inserting leg A's commit value.
        TestL2InteropCommitmentTree tree = new TestL2InteropCommitmentTree();
        tree.setAppender(address(this));
        tree.initialize();
        bytes32 emptyRoot = tree.root();
        uint256 lowIdx = AtomicInteropTestUtils.lowNullifierIndex(tree, cvA);
        (uint256 newIdx, bytes32 rootAfter) = tree.insert(cvA, lowIdx);
        IMTLeaf memory insertedLeaf = tree.leafAt(newIdx);
        bytes32 leafHashA = AtomicInteropTestUtils.leafHash(insertedLeaf);

        console.log("TAG (bytes4):");
        console.logBytes32(bytes32(ATOMIC_COMMIT_LEAF_TAG));
        console.log("bundleHash A (src=271, bytes=0xa1):");
        console.logBytes32(hA);
        console.log("bundleHash B (src=272, bytes=0xb2):");
        console.logBytes32(hB);
        console.log("legBundleHashes[0], [1] (ascending):");
        console.logBytes32(legs[0]);
        console.logBytes32(legs[1]);
        console.log("legSourceChainIds[0], [1] (positional):", chains[0], chains[1]);
        console.log("flowId = keccak(abi.encode(legs, chains, deadline=2000, slChainId=506)):");
        console.logBytes32(flowId);
        console.log("commitValue A = uint256(keccak(abi.encode(TAG, flowId, hA))):");
        console.logBytes32(bytes32(cvA));
        console.log("empty IMT root (zeros[32]):");
        console.logBytes32(emptyRoot);
        console.log("inserted leaf index, low-nullifier index:", newIdx, lowIdx);
        console.log("inserted leaf hash {value=cvA, nextIndex=0, nextValue=0}:");
        console.logBytes32(leafHashA);
        console.log("IMT root after inserting commitValue A:");
        console.logBytes32(rootAfter);
    }
}

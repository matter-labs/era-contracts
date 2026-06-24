// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @dev Domain tag mixed into a commit value's preimage so atomic-interop commit values cannot collide with
/// other hashes in the commitment tree; the `.v1` suffix versions the scheme (a new format gets a new tag).
/// `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, specHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));

/// @notice Proof that a flow leg's commit value WAS committed on its source chain by the deadline.
/// @dev The `deadline` is deliberately not a field here — it would be spoofable; it is re-derived from
/// `messageProof` instead (see {AtomicInteropProof}).
struct ImtInclusionProof {
    // --- source-chain L2->L1 message authenticating the commitment-tree root ---
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    uint16 messageTxNumberInBatch;
    uint256 messageIndex;
    bytes32[] messageProof;
    // --- IMT inclusion of the commit value at chainImtRoot ---
    IMTLeaf leaf;
    uint256 imtLeafIndex;
    bytes32[] imtProof;
}

/// @notice Proof that a flow leg's commit value was NOT committed on its source chain by the deadline (the
/// timeout / refund path) — an O(log n) low-nullifier non-inclusion in place of {ImtInclusionProof}'s
/// membership check.
/// @dev Because the tree is append-only, absence after the deadline implies absence at the deadline, so
/// (with the strict deadline split) a leg can never be both finalized and refunded.
struct ImtTimeoutProof {
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    uint16 messageTxNumberInBatch;
    uint256 messageIndex;
    bytes32[] messageProof;
    // --- IMT low-nullifier non-inclusion of the commit value at chainImtRoot ---
    IMTLeaf lowLeaf;
    uint256 lowLeafIndex;
    bytes32[] imtProof;
}

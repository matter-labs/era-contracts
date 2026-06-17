// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @notice Per-`(flowId, specHash)` lifecycle on each L2 escrow in the L1-free atomic flow.
///
///   Source:      `Unset -> Committed` (happy path: the source burn happens at `commitSend` and is
///                terminal — there is no source-side `execute`),
///                `Unset -> Committed -> Revertable -> Reverted` (timeout / refund).
///   Destination: `Unset -> Executable -> Executed`.
enum SpecState {
    Unset,
    Committed,
    Executable,
    Executed,
    Revertable,
    Reverted
}

/// @notice Declarative description of one cross-chain asset transfer (identical instance known to
/// source and destination), reused from the L1-coordinated interop stack so the asset mechanics can
/// route through the asset router / native token vault exactly like `L2FlowEscrow`.
///
/// `assetId` is derived externally as
/// `keccak256(abi.encode(originChainId, L2_NATIVE_TOKEN_VAULT_ADDR, originToken))`.
/// `depositor` carries the source-side payer so the escrow needs no separate depositor mapping.
struct SendSpec {
    uint256 destChainId;
    address recipient;
    uint256 originChainId;
    address originToken;
    uint256 amount;
    bytes erc20Data;
    address depositor;
}

/// @notice Inclusion proof that a spec's commit value is present in its origin chain's interop IMT
/// as of a root snapshot that settled no later than the flow deadline.
///
/// Authentication has two layers, both resolved against the interop root the verifying chain imported
/// for `(sourceChainId, batchNumber)`:
///   1. The origin {L2InteropCommitmentTree}'s `abi.encode(chainImtRoot, rootTimestamp)` L2->L1
///      message (sender pinned to the canonical commitment-tree address) is proven included; this
///      authenticates both the root and its bundled timestamp (covered by the batch validity proof).
///   2. `leaf` (with `leaf.value == commitValue`) at `imtLeafIndex` with `imtProof` hashes up to
///      `chainImtRoot` (delegated to {IndexedMerkleTreeLib.verifyInclusion}).
/// The escrow additionally requires `rootTimestamp <= deadline`.
struct ImtInclusionProof {
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    uint256 rootTimestamp;
    uint16 messageTxNumberInBatch;
    uint256 messageIndex;
    bytes32[] messageProof;
    IMTLeaf leaf;
    uint256 imtLeafIndex;
    bytes32[] imtProof;
}

/// @notice Non-inclusion proof used on the timeout/refund path. O(log n) thanks to the indexed tree.
///
/// Proves the target commit value was absent from its chain's interop IMT as of an authenticated root
/// whose bundled `rootTimestamp` is strictly after the deadline. Because the IMT is append-only,
/// absence in a post-deadline snapshot implies absence at the deadline, so the leg can no longer be
/// committed in time and the flow cannot finalize. Same two-layer authentication as
/// {ImtInclusionProof}; membership is replaced by the low-nullifier bracket
/// ({IndexedMerkleTreeLib.verifyNonInclusion}).
struct ImtNonInclusionProof {
    uint256 sourceChainId;
    uint256 batchNumber;
    bytes32 chainImtRoot;
    uint256 rootTimestamp;
    uint16 messageTxNumberInBatch;
    uint256 messageIndex;
    bytes32[] messageProof;
    IMTLeaf lowLeaf;
    uint256 lowLeafIndex;
    bytes32[] imtProof;
}

/// @dev Domain tag prepended to the preimage of a commit value so values cannot be confused with
/// other hashes. `commitValue = uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, flowId, specHash)))`.
bytes4 constant ATOMIC_COMMIT_LEAF_TAG = bytes4(keccak256("AtomicInterop.commit.v1"));

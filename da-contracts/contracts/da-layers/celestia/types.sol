// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

struct CelestiaZKStackInput {
    AttestationProof attestationProof;
    bytes equivalenceProof;
    bytes publicValues;
}

struct DataRootTuple {
    // Celestia block height the data root was included in.
    // Genesis block is height = 0.
    // First queryable block is height = 1.
    uint256 height;
    // Data root.
    bytes32 dataRoot;
}

/// @notice Contains the necessary parameters needed to verify that a data root tuple
/// was committed to, by the Blobstream smart contract, at some specif nonce.
struct AttestationProof {
    // the attestation nonce that commits to the data root tuple.
    uint256 tupleRootNonce;
    // the data root tuple that was committed to.
    DataRootTuple tuple;
    // the binary merkle proof of the tuple to the commitment.
    BinaryMerkleProof proof;
}

/// @notice Merkle Tree Proof structure.
struct BinaryMerkleProof {
    // List of side nodes to verify and calculate tree.
    bytes32[] sideNodes;
    // The key of the leaf to verify.
    uint256 key;
    // The number of leaves in the tree
    uint256 numLeaves;
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IExecutor, TOTAL_BLOBS_IN_COMMITMENT} from "../chain-interfaces/IExecutor.sol";

/// @notice Enough of a batch's commitment preimage to re-derive its Airbender commitment. One is
/// supplied per batch a transition names — for the previous batch as well as the proven one.
/// @dev Calldata only; never stored. Authenticated by recomputing the batch's stored commitment
/// from it, which pins every member except `airbenderBootloaderHeapHash`.
/// @dev `passThroughDataHash` is deliberately absent: it is derivable from the authenticated
/// `StoredBatchInfo`, so supplying it would add a word and a degree of operator freedom for nothing.
struct AirbenderCommitmentWitness {
    bytes32 metadataHash;
    bytes32 l2ToL1LogsHash;
    bytes32 stateDiffHash;
    /// @dev The bootloader heap hash as committed, whatever shape that is. The contract cannot tell
    /// which proof system produced it; the authentication check is what fixes it.
    bytes32 storedBootloaderHeapHash;
    bytes32 eventsQueueStateHash;
    bytes32 airbenderBootloaderHeapHash;
    bytes32[] blobAuxOutputWords;
}

/// @title Airbender commitment derivation
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Derives the Airbender-shape batch commitment from the Boojum-shape one that the chain
/// already stores.
///
/// @dev Boojum and Airbender build the same three-layer commitment
/// (`keccak(passThroughDataHash, metadataHash, auxiliaryOutputHash)`) over byte-identical
/// passthrough and metaparameters. They diverge in exactly two of the 36 words of the auxiliary
/// output preimage: the bootloader heap hash (Blake2s rather than Poseidon2-Goldilocks) and the
/// events queue hash, which Airbender pins to zero.
///
/// @dev So the Airbender commitment is a pure function of data the stored commitment already
/// authenticates, plus one extra word. It never has to be *committed to*: the operator re-supplies
/// the shared preimage at prove time and this library pins it against the commitment the chain
/// already holds. The Executor does record the result once a proof has verified it, so that the
/// next transition's `prev` is a value Airbender itself established (see
/// `deriveAirbenderCommitment`).
///
/// @dev What a derived commitment binds: the pass-through data (state root and enumeration index),
/// the metaparameters, the system-logs hash, the state-diff hash, and every blob word. The two words
/// left free are exactly the two Airbender does not reproduce — the Poseidon2-Goldilocks bootloader
/// heap hash, which it recomputes with Blake2s and which the guest constrains to its own execution,
/// and the events queue hash, which it pins to zero.
library AirbenderCommitment {
    /// @notice The witness does not open the batch's stored commitment.
    error CommitmentWitnessMismatch(bytes32 storedCommitment, bytes32 derivedCommitment);
    /// @notice The blob auxiliary output does not have the fixed number of words.
    error InvalidBlobAuxOutputLength(uint256 provided, uint256 expected);

    /// @notice Recomputes a batch's pass-through data hash from its stored info.
    /// @dev Mirrors `Committer._batchPassThroughData`, which reads exactly the two fields
    /// `StoredBatchInfo` carries. Deriving it here rather than taking it in the witness keeps it
    /// pinned by `storedBatchHashes` instead of merely checked.
    function passThroughDataHash(IExecutor.StoredBatchInfo memory _batch) internal pure returns (bytes32) {
        return
            keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(
                    _batch.indexRepeatedStorageChanges,
                    _batch.batchHash,
                    uint64(0), // index repeated storage changes in zkPorter
                    bytes32(0) // zkPorter batch hash
                )
            );
    }

    /// @notice Authenticates the witness against the batch's stored commitment, then derives that
    /// batch's Airbender commitment.
    /// @dev This is the value the Executor records for a batch it has just verified, and reads back
    /// as the `prev` end of the next transition. Recording it is what makes the lane a chain of
    /// Airbender-proven values rather than a sequence of independently derived ones — which is what
    /// the lane needs in order to stand alone when the Boojum lane is disabled.
    /// @dev MUST be called only after `_checkBatchHashMismatch` has authenticated `_batch`;
    /// beforehand, `_batch.commitment` is a value the caller chose.
    function deriveAirbenderCommitment(
        AirbenderCommitmentWitness memory _witness,
        IExecutor.StoredBatchInfo memory _batch
    ) internal pure returns (bytes32) {
        bytes32 ptHash = _authenticate(_witness, _batch);
        // Airbender pins the events queue slot to zero and hashes the heap with Blake2s.
        bytes32 airbenderAux = _auxiliaryOutputHash(_witness, _witness.airbenderBootloaderHeapHash, bytes32(0));
        return keccak256(abi.encode(ptHash, _witness.metadataHash, airbenderAux));
    }

    /// @notice The `prev` end of the first transition proved after the lane is enabled.
    /// @dev No Airbender commitment was ever recorded for that batch, because no Airbender proof
    /// verified it. The chain has to start somewhere, so it starts from the batch's committed data
    /// with the heap hash it was actually committed with — Poseidon2-Goldilocks rather than Blake2s.
    /// Airbender never inspects the previous batch's heap hash, so substituting it costs nothing,
    /// and taking the committed value rather than a constant keeps the seed a pure function of an
    /// authenticated commitment that anyone can recompute.
    /// @dev `airbenderBootloaderHeapHash` is ignored on this path; every other member is pinned by
    /// the same authentication check as the normal one.
    function deriveBootstrapCommitment(
        AirbenderCommitmentWitness memory _witness,
        IExecutor.StoredBatchInfo memory _batch
    ) internal pure returns (bytes32) {
        bytes32 ptHash = _authenticate(_witness, _batch);
        bytes32 seedAux = _auxiliaryOutputHash(_witness, _witness.storedBootloaderHeapHash, bytes32(0));
        return keccak256(abi.encode(ptHash, _witness.metadataHash, seedAux));
    }

    /// @dev Pins every witness member except `airbenderBootloaderHeapHash` by rebuilding the batch's
    /// stored commitment from it. Returns the pass-through hash, which both derivations reuse.
    function _authenticate(
        AirbenderCommitmentWitness memory _witness,
        IExecutor.StoredBatchInfo memory _batch
    ) private pure returns (bytes32 ptHash) {
        uint256 expectedWords = 2 * TOTAL_BLOBS_IN_COMMITMENT;
        if (_witness.blobAuxOutputWords.length != expectedWords) {
            revert InvalidBlobAuxOutputLength(_witness.blobAuxOutputWords.length, expectedWords);
        }

        ptHash = passThroughDataHash(_batch);

        bytes32 storedAux = _auxiliaryOutputHash(
            _witness,
            _witness.storedBootloaderHeapHash,
            _witness.eventsQueueStateHash
        );
        bytes32 derived = keccak256(abi.encode(ptHash, _witness.metadataHash, storedAux));
        if (derived != _batch.commitment) {
            revert CommitmentWitnessMismatch(_batch.commitment, derived);
        }
    }

    /// @dev Mirrors `Committer._batchAuxiliaryOutput`, with the two divergent words parameterised.
    function _auxiliaryOutputHash(
        AirbenderCommitmentWitness memory _witness,
        bytes32 _bootloaderHeapHash,
        bytes32 _eventsQueueStateHash
    ) private pure returns (bytes32) {
        return
            keccak256(
                // solhint-disable-next-line func-named-parameters
                abi.encodePacked(
                    _witness.l2ToL1LogsHash,
                    _witness.stateDiffHash,
                    _bootloaderHeapHash,
                    _eventsQueueStateHash,
                    _witness.blobAuxOutputWords
                )
            );
    }
}

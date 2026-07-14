// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Merkle} from "contracts/common/libraries/Merkle.sol";
import {MessageHashing} from "contracts/common/libraries/MessageHashing.sol";
import {L2Message} from "contracts/common/Messaging.sol";
import {SUPPORTED_PROOF_METADATA_VERSION} from "contracts/common/Config.sol";

/// @notice Builds REAL cross-chain message-inclusion proofs that the production {L2MessageVerification}
/// accepts — so tests can exercise `proveL2MessageInclusionShared` end-to-end instead of mocking it.
///
/// @dev A message-inclusion proof is a chain of Merkle hops the verifier walks
/// ({L2MessageVerification._proveL2LeafInclusionRecursive}):
///   hop 0 (non-final): the L2->L1 `_leaf` sits in a batch's local-logs root; that batch root is bound
///       into a `batchLeaf` (with its batch number + settlement `l1Timestamp`), which sits in the source
///       chain's chain-id root, yielding a `chainIdLeaf`.
///   hop 1 (final): the `chainIdLeaf` sits in the settlement layer's imported interop root, i.e.
///       `interopRoots[slChainId][slBlock]` — the base case the verifier checks against.
///
/// We build the *minimal* such proof: every Merkle sub-tree is a single leaf (index 0, empty sibling
/// path), so each `calculateRootMemory` returns its leaf unchanged and the whole chain collapses to a
/// deterministic `interopRoot` the caller seeds via `addInteropRoot`. This is a genuine (degenerate)
/// inclusion proof — the real verifier + real {MessageHashing} run over it — not a mock or a golden
/// vector, so every field (chain ids, batch number, settlement timestamp) is caller-controlled and the
/// proof cannot silently drift from production hashing.
///
/// The single-leaf shape can be widened per hop by passing non-empty `logLeafSiblings` with a matching
/// `messageIndex` (used to prove the message-coordinate forwarding path with a real >1-leaf log tree).
library InteropInclusionProofLib {
    struct Params {
        L2Message message; // the L2->L1 message being proven (sender + data authenticated into the leaf)
        uint256 messageIndex; // log-leaf Merkle mask (0 for a single-log batch)
        bytes32[] logLeafSiblings; // log-tree siblings (empty for a single-log batch)
        uint256 sourceChainId; // chain that emitted the message
        uint256 batchNumber; // source-chain batch the message settled in
        uint256 slChainId; // settlement layer the batch aggregated on
        uint256 slBlock; // settlement-layer block the imported interop root is anchored at
        uint256 l1BatchTimestamp; // settlement timestamp bound into the batch leaf
    }

    /// @notice Builds a two-hop (non-final -> final) inclusion proof and the interop root it resolves to.
    /// @return proof The `messageProof` blob accepted by `proveL2MessageInclusionShared`.
    /// @return interopRoot The value to seed at `interopRoots[slChainId][slBlock]` so the proof verifies.
    function buildInclusionProof(Params memory _p) internal pure returns (bytes32[] memory proof, bytes32 interopRoot) {
        bytes32 logLeaf = MessageHashing.getLeafHashFromLog(MessageHashing._l2MessageToLog(_p.message));
        // hop 0: log leaf -> batch-settlement root -> batch leaf -> chain-id root -> chain-id leaf.
        bytes32 batchSettlementRoot = Merkle.calculateRootMemory(_p.logLeafSiblings, _p.messageIndex, logLeaf);
        bytes32 batchLeaf = MessageHashing.batchLeafHash(batchSettlementRoot, _p.batchNumber, _p.l1BatchTimestamp);
        // Single-leaf batch tree, so the chain-id root equals the batch leaf.
        bytes32 chainIdLeaf = MessageHashing.chainIdLeafHash(batchLeaf, _p.sourceChainId);
        // hop 1 (final): single-leaf settlement tree, so the imported interop root equals the chain-id leaf.
        interopRoot = chainIdLeaf;

        uint256 n = _p.logLeafSiblings.length;
        // Layout: [meta0, logSiblings(n), l1Timestamp, batchLeafMask, slPackedBatchInfo, slChainId, meta1]
        proof = new bytes32[](n + 6);
        proof[0] = _metadata({_logLeafProofLen: n, _batchLeafProofLen: 0, _finalProofNode: false});
        for (uint256 i = 0; i < n; ++i) {
            proof[1 + i] = _p.logLeafSiblings[i];
        }
        proof[1 + n] = bytes32(_p.l1BatchTimestamp);
        proof[2 + n] = bytes32(uint256(0)); // batch-leaf Merkle mask (single-leaf batch tree)
        proof[3 + n] = bytes32(_p.slBlock << 128); // settlementLayerPackedBatchInfo: slBlock<<128 | mask(0)
        proof[4 + n] = bytes32(_p.slChainId);
        proof[5 + n] = _metadata({_logLeafProofLen: 0, _batchLeafProofLen: 0, _finalProofNode: true});
    }

    /// @notice Builds a single-hop *final* proof (no settlement-layer anchor). The verifier checks it
    /// directly against `interopRoots[sourceChainId][batchNumber]`, which must equal the returned root.
    /// @dev {AtomicInteropProof} accepts the message inclusion but then rejects the flow for having no
    /// settlement-layer anchor ({ProofMissingSettlementLayerAnchor}).
    function buildFinalNodeProof(
        L2Message memory _message,
        uint256 _messageIndex,
        bytes32[] memory _logLeafSiblings
    ) internal pure returns (bytes32[] memory proof, bytes32 interopRoot) {
        bytes32 logLeaf = MessageHashing.getLeafHashFromLog(MessageHashing._l2MessageToLog(_message));
        interopRoot = Merkle.calculateRootMemory(_logLeafSiblings, _messageIndex, logLeaf);

        uint256 n = _logLeafSiblings.length;
        proof = new bytes32[](n + 1);
        proof[0] = _metadata({_logLeafProofLen: n, _batchLeafProofLen: 0, _finalProofNode: true});
        for (uint256 i = 0; i < n; ++i) {
            proof[1 + i] = _logLeafSiblings[i];
        }
    }

    /// @dev Packs the proof-metadata word (top 4 bytes: version, logLeafProofLen, batchLeafProofLen,
    /// finalProofNode) exactly as {MessageHashing.parseProofMetadata} expects; the rest stays zero.
    function _metadata(
        uint256 _logLeafProofLen,
        uint256 _batchLeafProofLen,
        bool _finalProofNode
    ) private pure returns (bytes32) {
        return
            bytes32(
                (uint256(SUPPORTED_PROOF_METADATA_VERSION) << 248) |
                    (_logLeafProofLen << 240) |
                    (_batchLeafProofLen << 232) |
                    ((_finalProofNode ? uint256(1) : uint256(0)) << 224)
            );
    }
}

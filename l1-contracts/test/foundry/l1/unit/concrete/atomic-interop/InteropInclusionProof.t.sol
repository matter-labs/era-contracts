// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {InteropVerificationFixture} from "./InteropVerificationFixture.sol";
import {InteropInclusionProofLib} from "./InteropInclusionProofLib.sol";

import {L2Message} from "contracts/common/Messaging.sol";
import {L2_MESSAGE_VERIFICATION} from "contracts/common/l2-helpers/L2ContractInterfaces.sol";

/// @notice Tests the cross-chain message-inclusion layer ({L2MessageVerification.proveL2MessageInclusionShared})
/// directly against the programmatic proof builder ({InteropInclusionProofLib}) and a REAL interop-root
/// storage — no mocked verifier, no golden vectors.
///
/// This pins down the exact contract the atomic-interop proofs rely on: a proof verifies iff it resolves
/// to the imported interop root seeded for its `(settlementLayerChainId, settlementLayerBlock)`, and any
/// change to an authenticated field (settlement timestamp, source chain id, membership path) breaks it.
/// Because {AtomicInteropProof} authenticates roots through this same call, these tests let its unit
/// suite reuse the builder with confidence instead of mocking the verifier.
contract InteropInclusionProofTest is InteropVerificationFixture {
    uint256 internal constant SOURCE_CHAIN_ID = 271;
    uint256 internal constant SL_CHAIN_ID = 1; // L1
    uint256 internal constant BATCH_NUMBER = 100;
    uint256 internal constant SL_BLOCK = 500;
    uint256 internal constant L1_TIMESTAMP = 1_700_000_000;

    function setUp() public {
        _deployMessageVerification();
    }

    /// @dev A representative L2->L1 message; its `sender`/`data` are authenticated into the leaf.
    function _message() internal pure returns (L2Message memory) {
        return L2Message({txNumberInBatch: 0, sender: address(0xBEEF), data: abi.encode("payload")});
    }

    function _params(
        uint256 _messageIndex,
        bytes32[] memory _logSiblings,
        uint256 _l1BatchTimestamp
    ) internal pure returns (InteropInclusionProofLib.Params memory) {
        return
            InteropInclusionProofLib.Params({
                message: _message(),
                messageIndex: _messageIndex,
                logLeafSiblings: _logSiblings,
                sourceChainId: SOURCE_CHAIN_ID,
                batchNumber: BATCH_NUMBER,
                slChainId: SL_CHAIN_ID,
                slBlock: SL_BLOCK,
                l1BatchTimestamp: _l1BatchTimestamp
            });
    }

    // ============ happy path ============

    function test_realProof_verifiesAgainstSeededInteropRoot() public {
        (bytes32[] memory proof, bytes32 interopRoot) = InteropInclusionProofLib.buildInclusionProof(
            _params(0, new bytes32[](0), L1_TIMESTAMP)
        );
        _seedInteropRoot(SL_CHAIN_ID, SL_BLOCK, interopRoot);

        bool included = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            SOURCE_CHAIN_ID,
            BATCH_NUMBER,
            0,
            _message(),
            proof
        );
        assertTrue(included, "single-leaf proof should verify against the seeded interop root");
    }

    /// @dev A wider (>1-leaf) log tree still verifies, exercising a non-zero log-leaf Merkle mask.
    function test_realProof_multiLeafLogTreeVerifies() public {
        bytes32[] memory logSiblings = new bytes32[](1);
        logSiblings[0] = keccak256("sibling-log");
        uint256 messageIndex = 1; // message sits at index 1 under `logSiblings[0]`

        (bytes32[] memory proof, bytes32 interopRoot) = InteropInclusionProofLib.buildInclusionProof(
            _params(messageIndex, logSiblings, L1_TIMESTAMP)
        );
        _seedInteropRoot(SL_CHAIN_ID, SL_BLOCK, interopRoot);

        bool included = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            SOURCE_CHAIN_ID,
            BATCH_NUMBER,
            messageIndex,
            _message(),
            proof
        );
        assertTrue(included, "multi-leaf log-tree proof should verify");
    }

    /// @dev A final (single-hop) proof resolves directly against `interopRoots[sourceChainId][batchNumber]`.
    function test_finalNodeProof_verifiesAgainstDirectInteropRoot() public {
        (bytes32[] memory proof, bytes32 interopRoot) = InteropInclusionProofLib.buildFinalNodeProof(
            _message(),
            0,
            new bytes32[](0)
        );
        _seedInteropRoot(SOURCE_CHAIN_ID, BATCH_NUMBER, interopRoot);

        bool included = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            SOURCE_CHAIN_ID,
            BATCH_NUMBER,
            0,
            _message(),
            proof
        );
        assertTrue(included, "final-node proof should verify against the direct interop root");
    }

    // ============ negatives ============

    function test_unseededInteropRoot_doesNotVerify() public {
        (bytes32[] memory proof, ) = InteropInclusionProofLib.buildInclusionProof(
            _params(0, new bytes32[](0), L1_TIMESTAMP)
        );
        // Deliberately do NOT seed the interop root: the verifier finds a zero root and rejects.
        bool included = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            SOURCE_CHAIN_ID,
            BATCH_NUMBER,
            0,
            _message(),
            proof
        );
        assertFalse(included, "a proof whose interop root was never imported must not verify");
    }

    /// @dev The settlement timestamp is authenticated into the batch leaf. Seed the root for one
    /// timestamp, then present a proof carrying a different one: it no longer resolves to that root.
    function test_tamperedSettlementTimestamp_doesNotVerify() public {
        (, bytes32 interopRoot) = InteropInclusionProofLib.buildInclusionProof(
            _params(0, new bytes32[](0), L1_TIMESTAMP)
        );
        _seedInteropRoot(SL_CHAIN_ID, SL_BLOCK, interopRoot);

        // Rebuild the proof with a different timestamp but keep the seed for the original one.
        (bytes32[] memory tamperedProof, ) = InteropInclusionProofLib.buildInclusionProof(
            _params(0, new bytes32[](0), L1_TIMESTAMP + 1)
        );
        bool included = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            SOURCE_CHAIN_ID,
            BATCH_NUMBER,
            0,
            _message(),
            tamperedProof
        );
        assertFalse(included, "a tampered settlement timestamp must not resolve to the imported root");
    }

    /// @dev The source chain id is authenticated into the chain-id leaf. A proof built for one chain does
    /// not verify when presented as another chain's message.
    function test_wrongSourceChainId_doesNotVerify() public {
        (bytes32[] memory proof, bytes32 interopRoot) = InteropInclusionProofLib.buildInclusionProof(
            _params(0, new bytes32[](0), L1_TIMESTAMP)
        );
        _seedInteropRoot(SL_CHAIN_ID, SL_BLOCK, interopRoot);

        bool included = L2_MESSAGE_VERIFICATION.proveL2MessageInclusionShared(
            SOURCE_CHAIN_ID + 1, // proof was built for SOURCE_CHAIN_ID
            BATCH_NUMBER,
            0,
            _message(),
            proof
        );
        assertFalse(included, "a proof presented under the wrong source chain id must not verify");
    }
}

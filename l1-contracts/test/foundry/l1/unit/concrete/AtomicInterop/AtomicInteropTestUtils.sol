// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR,
    L2_MESSAGE_VERIFICATION_ADDR
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Minimal stand-in for the L2->L1 messenger system contract. The commitment tree calls
/// `sendToL1` on `L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR` from `initialize`/`insert`; in unit tests
/// there is no real system contract at that address, so we `vm.etch` this mock there. It mirrors the
/// real contract's behaviour of returning `keccak256(message)` and emitting the message event.
contract MockMessenger {
    event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);

    function sendToL1(bytes calldata _message) external returns (bytes32 hash) {
        hash = keccak256(_message);
        emit L1MessageSent(msg.sender, hash, _message);
    }
}

/// @notice Minimal asset-router stand-in that records the recover call the manager makes on the refund
/// path, so tests can assert the manager's orchestration without the full AR/NTV stack (the asset
/// movement itself is the AR/NTV's concern, exercised in the heavier anvil-interop suite).
///
/// The fund-touchless {AtomicFlowManager} only ever drives `recoverAtomicBurn` (the source burn happens
/// through the normal interop path during `sendBundle`, and the destination mint is driven by the
/// {InteropHandler}); this mock therefore exposes only that one entrypoint.
contract MockAtomicAssetRouter {
    uint256 public recoverCount;
    uint256 public lastChainId;
    bytes32 public lastAssetId;
    bytes public lastRecoverData;

    function recoverAtomicBurn(uint256 _destChainId, bytes32 _assetId, bytes calldata _recoverData) external {
        ++recoverCount;
        lastChainId = _destChainId;
        lastAssetId = _assetId;
        lastRecoverData = _recoverData;
    }
}

/// @notice Shared pure / view helpers mirroring the off-chain coordinator and the proof library, plus
/// the system-contract mock installation used by every atomic-interop unit test.
library AtomicInteropTestUtils {
    /// @dev Standard forge-std cheatcode handle, so library helpers can drive `vm.*` without inheriting
    /// from `Test`.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The IMT value inserted for a flow leg — must match {AtomicInteropProof.commitValue}.
    function commitValue(bytes32 _flowId, bytes32 _bundleHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _bundleHash)));
    }

    /// @notice Leaf hash in the engine's canonical layout — must match {IndexedMerkleTreeLib.hashLeaf}.
    function leafHash(IMTLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextIndex, _leaf.nextValue));
    }

    /// @notice Computes flowId exactly as {AtomicFlowManager}. Both arrays must be strictly ascending.
    function computeFlowId(
        bytes32[] memory _bundleHashes,
        uint256[] memory _chainIds,
        uint64 _deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_bundleHashes, _chainIds, _deadline));
    }

    /// @notice Walk the tree's leaves to find the low-nullifier slot for `_value` (the predecessor in
    /// the sorted linked list). Mirrors the off-chain index the appender would supply to `insert`.
    function lowNullifierIndex(IL2InteropCommitmentTree _tree, uint256 _value) internal view returns (uint256) {
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            IMTLeaf memory l = _tree.leafAt(i);
            if (l.value < _value && (l.nextValue == 0 || _value < l.nextValue)) {
                return i;
            }
        }
        revert("no low nullifier");
    }

    /// @notice Index of the leaf holding `_value`. Reverts if absent.
    function indexOfValue(IL2InteropCommitmentTree _tree, uint256 _value) internal view returns (uint256) {
        uint256 n = _tree.leafCount();
        for (uint256 i = 0; i < n; ++i) {
            if (_tree.leafAt(i).value == _value) {
                return i;
            }
        }
        revert("value not present");
    }

    /// @notice Install the system-contract dependencies the atomic-interop contracts reach for in unit
    /// tests:
    ///   - the L2->L1 messenger (so the commitment tree's `sendToL1` during `initialize`/`insert` works),
    ///   - the L2 message-verification contract, mocked to always accept the `(root)` message.
    /// The cross-chain authentication of that message (the real root check) is exercised end-to-end in
    /// the separate anvil-interop suite; here we isolate the manager / tree / proof logic from message
    /// verification. {AtomicInteropProof} ALSO re-parses the SAME `messageProof` bytes with the real
    /// {MessageHashing._getProofData} library (NOT mockable) to derive the settlement-layer block
    /// number, so tests must supply format-valid multi-hop proof bytes (see {slProofBytes}).
    function installSystemMocks() internal {
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new MockMessenger()).code);
        vm.mockCall(
            L2_MESSAGE_VERIFICATION_ADDR,
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
    }

    /// @notice Builds the minimal **format-valid multi-hop** L2-message inclusion proof bytes that
    /// {MessageHashing._getProofData} parses to a chosen settlement-layer block number `_slBlock` (with
    /// `finalProofNode == false`, i.e. a real SL-global proof carrying an SL anchor).
    ///
    /// The byte layout consumed by `_getProofData` / `parseProofMetadata` (with `logLeafProofLen == 0`
    /// and `batchLeafProofLen == 0`, so there are no path nodes — the mask words must therefore be 0):
    ///   [0] metadata header = version(0x01) << 248 | logLeafProofLen(0) << 240 | batchLeafProofLen(0)
    ///       << 232 | finalProofNode(0) << 224; the low 28 bytes MUST be zero so it is recognized as the
    ///       new (versioned) format.
    ///   [1] batchLeafProofMask = 0 (no batch-leaf path nodes, so the mask must be < 1).
    ///   [2] settlementLayerPackedBatchInfo = (_slBlock << 128) | mask(0).
    ///   [3] settlementLayerChainId.
    /// `messageIndex` (the leaf proof mask) must be 0 for this minimal proof, since `logLeafProofLen == 0`
    /// requires `index < 1`.
    function slProofBytes(uint256 _slBlock, uint256 _slChainId) internal pure returns (bytes32[] memory proof) {
        // version 0x01 in the top byte; logLeafProofLen=0, batchLeafProofLen=0, finalProofNode=0; rest 0.
        bytes32 metadata = bytes32(uint256(0x01) << 248);
        proof = new bytes32[](4);
        proof[0] = metadata;
        proof[1] = bytes32(uint256(0)); // batchLeafProofMask
        proof[2] = bytes32(_slBlock << 128); // (slBlock << 128) | settlementLayerBatchRootMask(0)
        proof[3] = bytes32(_slChainId);
    }

    /// @notice Builds a **final-node** (single-level / commit-based) proof — `finalProofNode == true`,
    /// which carries NO settlement-layer anchor. {AtomicInteropProof} must reject it with
    /// {ProofMissingSettlementLayerAnchor}. Layout: just the metadata header with `finalProofNode = 1`
    /// (logLeafProofLen=0, batchLeafProofLen=0 — `_getProofData` returns immediately after the leaf-proof
    /// step). `messageIndex` (leaf proof mask) must be 0 since the log-leaf path is empty.
    function finalNodeProofBytes() internal pure returns (bytes32[] memory proof) {
        // version 0x01; logLeafProofLen=0; batchLeafProofLen=0; finalProofNode=1 (byte index 3); rest 0.
        bytes32 metadata = bytes32((uint256(0x01) << 248) | (uint256(0x01) << 224));
        proof = new bytes32[](1);
        proof[0] = metadata;
    }
}

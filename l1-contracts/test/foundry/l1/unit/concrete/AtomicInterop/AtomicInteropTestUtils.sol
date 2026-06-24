// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {AtomicInteropProof} from "contracts/atomic-interop/libraries/AtomicInteropProof.sol";
import {ImtInclusionProof, ImtTimeoutProof} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IMessageVerification} from "contracts/common/interfaces/IMessageVerification.sol";
import {IMT, IMTLeaf, IndexedMerkleTree} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {FinalizeL1DepositParams, L2Log, L2Message, TxStatus} from "contracts/common/Messaging.sol";

/// @dev Metadata-version byte the proof format expects (see {MessageHashing.parseProofMetadata}).
uint256 constant SUPPORTED_PROOF_METADATA_VERSION = 1;

/// @notice Builds the minimal format-valid, non-final, single-settlement-hop message proof whose only
/// meaningful content is a chosen settlement-layer block and chain id.
/// @dev With `logLeafProofLen = 0` and `batchLeafProofLen = 0`, {MessageHashing._getProofData} reads the
/// log leaf as the batch settlement root and then lifts `(slBlock, slChainId)` straight out of the
/// trailing words — letting a mocked verifier + this proof exercise the deadline logic without a real
/// recursive proof. The message index / leaf-proof mask MUST be 0 for the empty log path to be valid.
/// @param _slBlock The settlement-layer block number to embed (extracted as `settlementLayerBatchNumber`).
/// @param _slChainId The settlement-layer chain id to embed.
function slProofBytes(uint256 _slBlock, uint256 _slChainId) pure returns (bytes32[] memory proof) {
    proof = new bytes32[](4);
    // version in byte 0; logLeafProofLen, batchLeafProofLen, finalProofNode all 0; remaining bytes 0
    // (so `metadata << 32 == 0` selects the new format).
    proof[0] = bytes32(SUPPORTED_PROOF_METADATA_VERSION << 248);
    proof[1] = bytes32(uint256(0)); // batchLeafProofMask (unused with a zero-length batch-leaf path)
    proof[2] = bytes32(_slBlock << 128); // packed (settlementLayerBatchNumber << 128) | batchRootMask(0)
    proof[3] = bytes32(_slChainId); // settlementLayerChainId
}

/// @notice A final-node (single-level / commit-based) proof, which carries no settlement-layer anchor and
/// must be rejected by the verifier.
function finalProofBytes() pure returns (bytes32[] memory proof) {
    proof = new bytes32[](1);
    // version in byte 0, finalProofNode (byte 3) = 1, all lengths 0.
    proof[0] = bytes32((SUPPORTED_PROOF_METADATA_VERSION << 248) | (uint256(1) << 224));
}

/// @notice A configurable stand-in for the message verifier. Only {proveL2MessageInclusionShared} is used
/// by {AtomicInteropProof}; injecting this instance avoids any `vm.etch`/`vm.mockCall` on a fixed address.
contract MockMessageVerification is IMessageVerification {
    bool internal _result = true;

    function setResult(bool _r) external {
        _result = _r;
    }

    function proveL2MessageInclusionShared(
        uint256,
        uint256,
        uint256,
        L2Message calldata,
        bytes32[] calldata
    ) external view returns (bool) {
        return _result;
    }

    function proveL2LogInclusionShared(
        uint256,
        uint256,
        uint256,
        L2Log calldata,
        bytes32[] calldata
    ) external pure returns (bool) {
        revert("not used");
    }

    function proveL2LeafInclusionShared(
        uint256,
        uint256,
        uint256,
        bytes32,
        bytes32[] calldata
    ) external pure returns (bool) {
        revert("not used");
    }

    function proveL1ToL2TransactionStatusShared(
        uint256,
        bytes32,
        uint256,
        uint256,
        uint16,
        bytes32[] calldata,
        TxStatus
    ) external pure returns (bool) {
        revert("not used");
    }

    function proveL1DepositParamsInclusion(FinalizeL1DepositParams calldata) external pure returns (bool) {
        revert("not used");
    }
}

/// @notice External wrapper around the {AtomicInteropProof} library so its `calldata` verification
/// entrypoints can be called (and their reverts asserted) from tests.
contract AtomicInteropProofHarness {
    function verifyInclusion(
        ImtInclusionProof calldata _proof,
        IMessageVerification _verifier,
        address _commitmentTreeSender,
        uint256 _expectedSourceChainId,
        uint256 _commitValue,
        uint256 _deadline
    ) external view returns (uint256 slChainId) {
        return
            AtomicInteropProof.verifyInclusion(
                _proof,
                _verifier,
                _commitmentTreeSender,
                _expectedSourceChainId,
                _commitValue,
                _deadline
            );
    }

    function verifyTimeout(
        ImtTimeoutProof calldata _proof,
        IMessageVerification _verifier,
        address _commitmentTreeSender,
        uint256 _expectedSourceChainId,
        uint256 _commitValue,
        uint256 _deadline
    ) external view returns (uint256 slChainId) {
        return
            AtomicInteropProof.verifyTimeout(
                _proof,
                _verifier,
                _commitmentTreeSender,
                _expectedSourceChainId,
                _commitValue,
                _deadline
            );
    }

    function commitValue(bytes32 _flowId, bytes32 _specHash) external pure returns (uint256) {
        return AtomicInteropProof.commitValue(_flowId, _specHash);
    }
}

/// @notice A minimal real Indexed-Merkle-Tree harness standing in for the source chain's commitment tree,
/// used to construct genuine inclusion and low-nullifier non-inclusion proofs against a real
/// {IndexedMerkleTree} root (the membership engine the proof library delegates to).
contract InteropCommitmentTreeHarness {
    using IndexedMerkleTree for IMT;

    IMT internal _tree;

    function setup() external {
        _tree.setup();
    }

    function insert(uint256 _value, uint256 _lowLeafIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        return _tree.insert(_value, _lowLeafIndex);
    }

    function root() external view returns (bytes32) {
        return _tree.root();
    }

    function leafAt(uint256 _index) external view returns (IMTLeaf memory) {
        return _tree.leaves[_index];
    }

    function merklePath(uint256 _index) external view returns (bytes32[] memory) {
        return _tree.merklePath(_index);
    }

    function leafCount() external view returns (uint256) {
        return _tree.tree._leafNumber;
    }

    /// @notice Index of the leaf whose value equals `_value`. Reverts if absent.
    function indexOfValue(uint256 _value) external view returns (uint256) {
        uint256 n = _tree.tree._leafNumber;
        for (uint256 i = 0; i < n; ++i) {
            if (_tree.leaves[i].value == _value) {
                return i;
            }
        }
        revert("value not present");
    }

    /// @notice Index of the low-nullifier leaf bracketing an absent `_value`
    /// (`value < _value < nextValue`, or `nextValue == 0`). Reverts if `_value` is actually present.
    function lowNullifierIndex(uint256 _value) external view returns (uint256) {
        uint256 n = _tree.tree._leafNumber;
        for (uint256 i = 0; i < n; ++i) {
            IMTLeaf memory leaf = _tree.leaves[i];
            if (leaf.value < _value && (leaf.nextValue == 0 || _value < leaf.nextValue)) {
                return i;
            }
        }
        revert("no low nullifier");
    }
}

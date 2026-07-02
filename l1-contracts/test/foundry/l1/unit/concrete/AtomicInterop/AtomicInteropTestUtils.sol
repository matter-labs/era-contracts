// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
import {IL2InteropCommitmentTree} from "contracts/atomic-interop/IL2InteropCommitmentTree.sol";
import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {AtomicFlowManager} from "contracts/atomic-interop/AtomicFlowManager.sol";
import {IAtomicRecoverable} from "contracts/atomic-interop/IAtomicRecoverable.sol";
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

/// @notice Minimal {IAtomicRecoverable} stand-in that records the recover call the manager forwards on
/// the refund path, so tests can assert the manager's orchestration (it forwards each bundle call's
/// `(destChainId, data)` to the call's target) without the full AR/NTV stack — the actual asset
/// movement / depositor-swap is the AR's concern, exercised in the heavier anvil-interop suite.
///
/// `willRecover` controls the returned `recovered` flag so tests can model both a recoverable target
/// (true) and a target that recognises nothing to recover (false).
contract MockAtomicAssetRouter is IAtomicRecoverable {
    uint256 public recoverCount;
    uint256 public lastDestChainId;
    bytes public lastCallData;
    bool internal _willRecover = true;

    function setWillRecover(bool _v) external {
        _willRecover = _v;
    }

    function recoverAtomicCall(uint256 _destChainId, bytes calldata _callData) external returns (bool recovered) {
        lastDestChainId = _destChainId;
        lastCallData = _callData;
        recovered = _willRecover;
        if (recovered) {
            ++recoverCount;
        }
    }
}

/// @notice Test-only subclass that overrides the commitment tree's canonical `appender()` getter so a
/// unit test can register an arbitrary appender (e.g. itself, or a test-deployed manager). Production
/// returns the fixed {AtomicFlowManager} address; this lets tests inject without canonical deployment.
contract TestL2InteropCommitmentTree is L2InteropCommitmentTree {
    address private _appenderOverride;

    function setAppender(address _a) external {
        _appenderOverride = _a;
    }

    function appender() public view override returns (address) {
        return _appenderOverride;
    }
}

/// @notice Test-only subclass that overrides the manager's canonical collaborator getters so a unit
/// test can wire its own tree and act as the interop center + handler. Production returns the fixed
/// built-in addresses; these overrides let tests deploy multiple independent stacks.
contract TestAtomicFlowManager is AtomicFlowManager {
    address private _treeOverride;
    address private _interopCenterOverride;
    address private _interopHandlerOverride;

    function wire(address _tree, address _ic, address _ih) external {
        _treeOverride = _tree;
        _interopCenterOverride = _ic;
        _interopHandlerOverride = _ih;
    }

    function commitmentTree() public view override returns (address) {
        return _treeOverride;
    }

    function interopCenter() public view override returns (address) {
        return _interopCenterOverride;
    }

    function interopHandler() public view override returns (address) {
        return _interopHandlerOverride;
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

    /// @notice Leaf hash in the engine's canonical layout — must match {IndexedMerkleTree.hashLeaf}.
    function leafHash(IMTLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextIndex, _leaf.nextValue));
    }

    /// @notice Computes flowId exactly as {AtomicFlowManager}: the 4-field preimage of
    /// `legBundleHashes` (strictly ascending), `legSourceChainIds` (positional, aligned 1:1 with the
    /// hashes), `deadline`, and `settlementLayerChainId`.
    function computeFlowId(
        bytes32[] memory _bundleHashes,
        uint256[] memory _legSourceChainIds,
        uint64 _deadline,
        uint256 _settlementLayerChainId
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_bundleHashes, _legSourceChainIds, _deadline, _settlementLayerChainId));
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
    /// {MessageHashing._getProofData} parses to a chosen settlement-layer timestamp (batch settlement timestamp `_t`), SL
    /// chain id `_slChainId` (with `finalProofNode == false`,
    /// i.e. a real SL-global proof carrying an SL anchor).
    ///
    /// The byte layout consumed by `_getProofData` / `parseProofMetadata` (with `logLeafProofLen == 0`
    /// and `batchLeafProofLen == 0`, so there are no path nodes — the mask words must therefore be 0):
    ///   [0] metadata header = version(0x01) << 248 | logLeafProofLen(0) << 240 | batchLeafProofLen(0)
    ///       << 232 | finalProofNode(0) << 224; the low 28 bytes MUST be zero so it is recognized as the
    ///       new (versioned) format.
    ///   [1] batchSettlementTimestamp `t` — folded into the chain batch leaf and read back by the
    ///       atomic-interop verifier as `pd.batchSettlementTimestamp`.
    ///   [2] batchLeafProofMask = 0 (no batch-leaf path nodes, so the mask must be < 1).
    ///   [3] settlementLayerPackedBatchInfo = (_slBlock << 128) | mask(0).
    ///   [4] settlementLayerChainId.
    /// `messageIndex` (the leaf proof mask) must be 0 for this minimal proof, since `logLeafProofLen == 0`
    /// requires `index < 1`.
    function slProofBytes(
        uint256 _slBlock,
        uint256 _slChainId,
        uint256 _t
    ) internal pure returns (bytes32[] memory proof) {
        // version 0x01 in the top byte; logLeafProofLen=0, batchLeafProofLen=0, finalProofNode=0; rest 0.
        bytes32 metadata = bytes32(uint256(0x01) << 248);
        proof = new bytes32[](5);
        proof[0] = metadata;
        proof[1] = bytes32(_t); // batchSettlementTimestamp
        proof[2] = bytes32(uint256(0)); // batchLeafProofMask
        proof[3] = bytes32(_slBlock << 128); // (slBlock << 128) | settlementLayerBatchRootMask(0)
        proof[4] = bytes32(_slChainId);
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

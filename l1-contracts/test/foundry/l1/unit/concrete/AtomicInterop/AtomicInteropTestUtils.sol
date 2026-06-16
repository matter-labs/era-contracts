// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Vm} from "forge-std/Vm.sol";

import {IMTLeaf} from "contracts/common/libraries/IndexedMerkleTree.sol";
import {SendSpec, ATOMIC_COMMIT_LEAF_TAG} from "contracts/atomic-interop/IAtomicInterop.sol";
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

/// @notice Minimal asset-router stand-in that records the burn / recover / mint calls the escrow makes,
/// so tests can assert the escrow's orchestration without the full AR/NTV stack (the asset movement
/// itself is the AR/NTV's concern, exercised in the heavier anvil-interop suite). It exposes exactly
/// the three entrypoints the escrow drives: `atomicBridgeBurn` (source commit), `recoverAtomicBurn`
/// (refund) and `finalizeDeposit` (destination mint).
contract MockAtomicAssetRouter {
    uint256 public atomicBurnCount;
    uint256 public recoverCount;
    uint256 public finalizeDepositCount;
    uint256 public lastChainId;
    bytes32 public lastAssetId;

    function atomicBridgeBurn(uint256 _destChainId, bytes32 _assetId, address, bytes calldata) external {
        ++atomicBurnCount;
        lastChainId = _destChainId;
        lastAssetId = _assetId;
    }

    function recoverAtomicBurn(uint256 _destChainId, bytes32 _assetId, bytes calldata) external {
        ++recoverCount;
        lastChainId = _destChainId;
        lastAssetId = _assetId;
    }

    function finalizeDeposit(uint256 _chainId, bytes32 _assetId, bytes calldata) external payable {
        ++finalizeDepositCount;
        lastChainId = _chainId;
        lastAssetId = _assetId;
    }
}

/// @notice Shared pure / view helpers mirroring the off-chain coordinator and the proof library, plus
/// the system-contract mock installation used by every atomic-interop unit test.
library AtomicInteropTestUtils {
    /// @dev Standard forge-std cheatcode handle, so library helpers can drive `vm.*` without inheriting
    /// from `Test`.
    Vm internal constant vm = Vm(address(uint160(uint256(keccak256("hevm cheat code")))));

    /// @notice The IMT value inserted for a flow leg — must match {AtomicInteropProof.commitValue}.
    function commitValue(bytes32 _flowId, bytes32 _specHash) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(ATOMIC_COMMIT_LEAF_TAG, _flowId, _specHash)));
    }

    /// @notice Leaf hash in the engine's canonical layout — must match {IndexedMerkleTreeLib.hashLeaf}.
    function leafHash(IMTLeaf memory _leaf) internal pure returns (bytes32) {
        return keccak256(abi.encode(_leaf.value, _leaf.nextIndex, _leaf.nextValue));
    }

    function specHashOf(SendSpec memory _spec) internal pure returns (bytes32) {
        return keccak256(abi.encode(_spec));
    }

    /// @notice Computes flowId exactly as {AtomicFlowEscrow}. Both arrays must be strictly ascending.
    function computeFlowId(
        bytes32[] memory _specHashes,
        uint256[] memory _chainIds,
        uint64 _deadline
    ) internal pure returns (bytes32) {
        return keccak256(abi.encode(_specHashes, _chainIds, _deadline));
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
    ///   - the L2 message-verification contract, mocked to always accept the `(root, timestamp)` message.
    /// The cross-chain authentication of that message is exercised end-to-end in the separate
    /// anvil-interop suite; here we isolate the escrow / tree / proof logic from message verification.
    function installSystemMocks() internal {
        vm.etch(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, address(new MockMessenger()).code);
        vm.mockCall(
            L2_MESSAGE_VERIFICATION_ADDR,
            abi.encodeWithSelector(IMessageVerification.proveL2MessageInclusionShared.selector),
            abi.encode(true)
        );
    }
}

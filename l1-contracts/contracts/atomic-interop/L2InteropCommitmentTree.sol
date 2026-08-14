// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IndexedMerkleTree, IMT, IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {IL2InteropCommitmentTree} from "./IL2InteropCommitmentTree.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    INTEROP_COMMITMENT_LEAF_HOOK
} from "../common/l2-helpers/L2ContractAddresses.sol";
import {L1MessageGasLib} from "../l2-system/zksync-os/L1MessageGasLib.sol";
import {Unauthorized, NotSelfCall, NotEnoughGasSupplied} from "../l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {CommitmentTreeNotAppender, InteropCommitmentLeafHookFailed} from "./AtomicInteropErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See {IL2InteropCommitmentTree}. A thin shell over the shared dynamic-height Indexed Merkle
/// Tree engine ({IndexedMerkleTree}).
/// @dev The bootloader reads the root directly from this contract's storage at every batch boundary, and
/// each insert is additionally reported to {INTEROP_COMMITMENT_LEAF_HOOK} as an L2->L1 log. See
/// {protocol-docs/atomicity/imt.md#the-root-is-read-from-storage-never-published}.
/// @dev STORAGE LAYOUT IS CONSENSUS-CRITICAL. The bootloader reads the engine's root
/// `_imt.tree._nodes[_imt.tree._height][0]` directly: it loads `_height` from slot 0 and derives the
/// `_nodes[_height][0]` slot from the `_nodes` base slot 2. An uninitialized tree reads as `bytes32(0)`.
contract L2InteropCommitmentTree is IL2InteropCommitmentTree {
    using IndexedMerkleTree for IMT;

    /// @dev The append-only indexed tree. MUST stay at slot 0 — the bootloader derives the engine's
    /// root slot from this position (see contract doc). A non-zero `_imt.tree._leafNumber` also serves
    /// as the "initialized" flag.
    IMT internal _imt;

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @inheritdoc IL2InteropCommitmentTree
    /// @dev The appender is a fixed built-in address, so there is no wiring parameter; `_imt.setup()`
    /// reverts if the tree was already seeded.
    function initL2() external onlyUpgrader {
        _imt.setup();
        emit RootUpdated(0, _imt.root());
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function insert(uint256 _value, uint256 _lowNullifierIndex) external returns (uint256 newIndex, bytes32 newRoot) {
        if (msg.sender != appender()) {
            revert CommitmentTreeNotAppender(msg.sender);
        }
        // Value / low-nullifier validation (non-zero, no duplicates, correct bracket) is enforced by
        // the engine and surfaces its own `IMT*` errors.
        (newIndex, newRoot) = _imt.insert(_value, _lowNullifierIndex);
        // Record the inserted value as an L2->L1 log via the system hook, so the full set of inserted
        // values — and therefore the whole tree — is always reconstructible from L1 DA, independently
        // of the chain's state-diff DA choice. The values are logged in insertion order (one hook call
        // per insert); the O(log n) `nextIndex`/`nextValue` links are re-derivable from the sorted set.
        _reportLeaf(_value);
        emit RootUpdated(newIndex, newRoot);
    }

    /// @dev Reports a single inserted value to the interop commitment leaf system hook. The calldata is
    /// exactly the 32-byte value, which the ZKsync OS hook records as the `value` of an L2->L1 log.
    /// @dev First burns the gas equivalent of recording that log ({L1MessageGasLib.estimateLogGas}):
    /// the hook charges the ZKsync OS `native` resource for the log, and the burn is the caller-side
    /// EVM-gas accounting, mirroring `L1Messenger.sendToL1`.
    function _reportLeaf(uint256 _value) private {
        _burnLogGas();
        // solhint-disable-next-line avoid-low-level-calls
        (bool ok, ) = INTEROP_COMMITMENT_LEAF_HOOK.call(abi.encodePacked(_value));
        require(ok, InteropCommitmentLeafHookFailed());
    }

    /// @dev Burns the gas equivalent of recording one L2->L1 log by forwarding it to the self-only
    /// reverting `fallback`, mirroring `L1Messenger.burnGas`.
    function _burnLogGas() private {
        uint256 gasToBurn = L1MessageGasLib.estimateLogGas();

        // If there isn't enough gas to burn the desired amount, revert.
        if ((gasleft() * 63) / 64 < gasToBurn) {
            revert NotEnoughGasSupplied();
        }

        // solhint-disable-next-line avoid-low-level-calls
        (bool success, ) = address(this).call{gas: gasToBurn}("");
        success; // ignored
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function root() external view returns (bytes32) {
        return _imt.root();
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafCount() external view returns (uint256) {
        return _imt.tree._leafNumber;
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function leafAt(uint256 _index) external view returns (IMTLeaf memory) {
        return _imt.leaves[_index];
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function merklePath(uint256 _index) external view returns (bytes32[] memory) {
        return _imt.merklePath(_index);
    }

    /// @inheritdoc IL2InteropCommitmentTree
    function appender() public view virtual returns (address) {
        return L2_ATOMIC_FLOW_MANAGER_ADDR;
    }

    /// @dev Self-call target that consumes the gas forwarded by `_burnLogGas`. Only callable by this
    /// contract; `invalid()` reverts the self-call. Non-payable so it does not affect `address ->
    /// L2InteropCommitmentTree` conversions elsewhere.
    fallback() external {
        require(msg.sender == address(this), NotSelfCall());
        assembly {
            invalid()
        }
    }
}

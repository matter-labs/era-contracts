// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Generic per-sender fact recorder backed by an Indexed Merkle Tree.
///
/// Any contract may call `recordFact(fact, lowLeafIndex)` to commit `(msg.sender, fact)` into
/// the tree as a single leaf with value `uint256(keccak256(abi.encode(sender, fact)))`. Including
/// the sender prevents fact-name collisions across contracts that share the recorder.
///
/// After every insert the new root is published to L1 via the L2-to-L1 messenger so that other
/// chains can verify inclusion or non-inclusion of facts against a trusted snapshot.
interface IIMTFactRecorder {
    /// @notice Emitted on every successful `recordFact` call.
    event FactRecorded(
        address indexed sender,
        bytes32 indexed fact,
        uint256 leafValue,
        uint256 leafIndex,
        bytes32 newRoot
    );

    /// @notice Insert `(msg.sender, _fact)` into the IMT and publish the new root to L1.
    /// @param _fact Caller-supplied fact name. Together with `msg.sender` this forms the leaf value.
    /// @param _lowLeafIndex Index of the leaf in the IMT whose `(value, nextValue)` interval
    /// brackets the new leaf value. Caller computes this off-chain by walking `imtLeafAt`.
    /// @return newRoot The IMT root after insertion.
    /// @return newLeafIndex Index assigned to the new leaf.
    function recordFact(bytes32 _fact, uint256 _lowLeafIndex) external returns (bytes32 newRoot, uint256 newLeafIndex);

    /// @notice Pure helper: leaf value for `(sender, fact)`.
    function factValue(address _sender, bytes32 _fact) external pure returns (uint256);

    function imtRoot() external view returns (bytes32);

    function imtLeafCount() external view returns (uint256);

    function imtLeafAt(uint256 _index) external view returns (IMTLeaf memory);

    function imtMerklePath(uint256 _index) external view returns (bytes32[] memory);

    function imtIndexOf(uint256 _value) external view returns (uint256);
}

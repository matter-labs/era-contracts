// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {IIMTFactRecorder} from "./IIMTFactRecorder.sol";
import {IndexedMerkleTreeLib, IMT, IMTLeaf} from "../common/libraries/IndexedMerkleTree.sol";
import {L2ContractHelper} from "../common/l2-helpers/L2ContractHelper.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";

/// @notice Pure helper for the leaf value the recorder commits for a `(sender, fact)` pair.
/// Exposed as a library so other contracts (e.g. `Simulator`) can compute the same value
/// inline, without an external call into the recorder.
library FactHashing {
    function factValue(address _sender, bytes32 _fact) internal pure returns (uint256) {
        return uint256(keccak256(abi.encode(_sender, _fact)));
    }
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice See `IIMTFactRecorder` for protocol-level docs.
/// @dev Important: L2 contracts are not allowed to have any immutable variables or constructors.
/// State is initialized through `initL2`, called once via `L2_COMPLEX_UPGRADER_ADDR` during the
/// genesis upgrade.
contract IMTFactRecorder is IIMTFactRecorder {
    using IndexedMerkleTreeLib for IMT;

    IMT internal _imt;

    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) revert Unauthorized(msg.sender);
        _;
    }

    /// @notice One-shot initializer. Reverts on second call (the IMT library checks `leafCount`).
    function initL2() external onlyUpgrader {
        _imt.setup();
    }

    /// @inheritdoc IIMTFactRecorder
    function recordFact(bytes32 _fact, uint256 _lowLeafIndex) external returns (bytes32 newRoot, uint256 newLeafIndex) {
        uint256 leafValue = FactHashing.factValue(msg.sender, _fact);
        (newLeafIndex, newRoot) = _imt.insert(leafValue, _lowLeafIndex);

        // ── DA REQUIREMENT ──────────────────────────────────────────────────────────────
        // Publish the full fact payload (sender, fact, derived leafValue, assigned leafIndex,
        // and the resulting root) to L1, not just the root. Off-chain consumers on other
        // chains need every component to:
        //   - reconstruct `leafValue` independently as `keccak256(abi.encode(sender, fact))`
        //     and confirm it matches what the source chain inserted,
        //   - locate the leaf in this IMT snapshot at `leafIndex` for inclusion proofs,
        //   - reproduce the chained linked-list view of the IMT (sender + fact identifies
        //     which atomicity flow this entry corresponds to).
        // Sending only the root would put the entire fact-graph behind the source chain's
        // willingness to serve view queries; that's a DA hole, since L1 wouldn't be enough
        // to verify what was recorded. This payload guarantees DA on L1 for every fact.
        L2ContractHelper.sendMessageToL1(abi.encode(msg.sender, _fact, leafValue, newLeafIndex, newRoot));

        emit FactRecorded({
            sender: msg.sender,
            fact: _fact,
            leafValue: leafValue,
            leafIndex: newLeafIndex,
            newRoot: newRoot
        });
    }

    /// @inheritdoc IIMTFactRecorder
    function factValue(address _sender, bytes32 _fact) external pure returns (uint256) {
        return FactHashing.factValue(_sender, _fact);
    }

    /// @inheritdoc IIMTFactRecorder
    function imtRoot() external view returns (bytes32) {
        return _imt.root();
    }

    /// @inheritdoc IIMTFactRecorder
    function imtLeafCount() external view returns (uint256) {
        return _imt.leafCount;
    }

    /// @inheritdoc IIMTFactRecorder
    function imtLeafAt(uint256 _index) external view returns (IMTLeaf memory) {
        return _imt.leaves[_index];
    }

    /// @inheritdoc IIMTFactRecorder
    function imtMerklePath(uint256 _index) external view returns (bytes32[] memory) {
        return _imt.merklePath(_index);
    }

    /// @inheritdoc IIMTFactRecorder
    function imtIndexOf(uint256 _value) external view returns (uint256) {
        return _imt.valueToIndex[_value];
    }
}

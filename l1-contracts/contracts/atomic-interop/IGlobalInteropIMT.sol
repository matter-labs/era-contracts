// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1 registry of per-chain interop-IMT roots and the aggregated global interop-IMT.
///
/// This is the L1-free atomic interop analogue of `MessageRoot`: when a chain settles a batch,
/// its current interop IMT root (and the DA commitment to that IMT's preimage) is exposed on L1
/// — by the operator in the execute batch data, after which the chain's `Executor` calls
/// `submitChainRoot` here. The registry maintains:
///
///   global_imt_root -> chain -> imt        (each chain's leaf is updated *in place*)
///   historical_root -> (block, timestamp)  (append-only snapshots of the global root)
///
/// L2s import the historical global root (see `L2GlobalInteropRootImporter`) and use it to verify
/// that a flow's legs were all committed before its deadline — without any L1 coordinator.
///
/// Two Merkle trees are maintained:
///   - the **in-place global tree** (`FullMerkle`): leaf `i` = `keccak256(chainImtRoot, chainId)`,
///     updated in place per chain; its root is `globalRoot`;
///   - the **append-only history tree** (`DynamicIncrementalMerkle`): a leaf
///     `keccak256(block, timestamp, globalRoot)` is appended every time `globalRoot` advances; its
///     root (`historyRoot`) is an accumulating commitment to the full sequence of global roots.
/// A `mapping(globalRoot => blockNumber)` records the L1 block at which each global root was appended.
interface IGlobalInteropIMT {
    /// @notice Emitted whenever a chain's interop IMT root is (re)submitted.
    event ChainRootSubmitted(
        uint256 indexed chainId,
        uint256 indexed batchNumber,
        bytes32 chainImtRoot,
        bytes32 daCommitment,
        bytes32 globalRoot
    );

    /// @notice Emitted whenever the aggregated global root advances. `blockNumber`/`timestamp` are
    /// the L1 values the importer keys historical roots on.
    event GlobalRootUpdated(uint256 indexed blockNumber, uint256 timestamp, bytes32 globalRoot);

    /// @notice Emitted when a chain is first seen and assigned a leaf in the global tree.
    event ChainRegistered(uint256 indexed chainId, uint256 leafIndex);

    /// @notice Emitted when a `(block, timestamp, globalRoot)` snapshot is appended to the history tree.
    event HistoryAppended(
        uint256 indexed leafIndex,
        uint256 blockNumber,
        uint256 timestamp,
        bytes32 globalRoot,
        bytes32 historyRoot
    );

    /// @notice Emitted when an address is (de)authorized to submit roots for a chain.
    event SubmitterSet(uint256 indexed chainId, address indexed submitter, bool allowed);

    /// @notice Emitted when an address is (de)authorized to submit roots for any chain (demo operator).
    event GlobalSubmitterSet(address indexed submitter, bool allowed);

    /// @notice Submit a chain's interop IMT root for a freshly executed batch.
    /// @dev Callable by an authorized per-chain submitter (the chain's `Executor` in production)
    /// or a global submitter (a trusted operator in the demo). Updates the chain's leaf in the
    /// global tree in place and appends a historical global-root snapshot for the current L1 block.
    /// @param _chainId The chain whose IMT root is being exposed.
    /// @param _batchNumber The settled batch number; must be the chain's previous batch number + 1.
    /// @param _chainImtRoot The chain's interop IMT root after the batch.
    /// @param _daCommitment Commitment (e.g. blob/calldata hash) to the IMT preimage data.
    function submitChainRoot(
        uint256 _chainId,
        uint256 _batchNumber,
        bytes32 _chainImtRoot,
        bytes32 _daCommitment
    ) external;

    /// @notice Authorize/deauthorize a submitter for a specific chain. Owner only.
    function setSubmitter(uint256 _chainId, address _submitter, bool _allowed) external;

    /// @notice Authorize/deauthorize a submitter for all chains (demo operator). Owner only.
    function setGlobalSubmitter(address _submitter, bool _allowed) external;

    /// @notice Current aggregated global interop-IMT root (root of the in-place global tree).
    function globalRoot() external view returns (bytes32);

    /// @notice Current root of the append-only history tree of `(block, timestamp, globalRoot)` leaves.
    function historyRoot() external view returns (bytes32);

    /// @notice Number of snapshots appended to the history tree.
    function historyLeafCount() external view returns (uint256);

    /// @notice The L1 block number at which `_globalRoot` was appended to the history tree (0 if never).
    function historyBlockOfRoot(bytes32 _globalRoot) external view returns (uint256);

    /// @notice The latest global root recorded at L1 block `_blockNumber` (0 if none).
    function globalRootAtBlock(uint256 _blockNumber) external view returns (bytes32);

    /// @notice The L1 timestamp recorded for the global root at L1 block `_blockNumber`.
    function timestampAtBlock(uint256 _blockNumber) external view returns (uint256);

    /// @notice A chain's current interop IMT root (0 if never submitted).
    function chainRootOf(uint256 _chainId) external view returns (bytes32);

    /// @notice A chain's leaf index in the global tree.
    function leafIndexOf(uint256 _chainId) external view returns (uint256);

    /// @notice Whether a chain has been registered (has a leaf).
    function isChainRegistered(uint256 _chainId) external view returns (bool);

    /// @notice The chain's last submitted batch number.
    function currentBatchNumber(uint256 _chainId) external view returns (uint256);

    /// @notice The DA commitment recorded for a chain's batch.
    function daCommitmentOf(uint256 _chainId, uint256 _batchNumber) external view returns (bytes32);

    /// @notice Number of distinct L1 blocks at which a global root was recorded.
    function historyLength() external view returns (uint256);

    /// @notice The L1 block number of the `_i`-th recorded global root (ascending).
    function historyBlockAt(uint256 _i) external view returns (uint256);

    /// @notice Merkle path proving the chain's current leaf against the current global root.
    function merklePathForChain(uint256 _chainId) external view returns (bytes32[] memory);
}

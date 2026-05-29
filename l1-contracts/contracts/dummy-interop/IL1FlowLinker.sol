// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {L2Message} from "../common/Messaging.sol";

/// @notice Inclusion proof bundle for one chain's commit log. The linker re-verifies each
/// via `IMessageVerification.proveL2MessageInclusionShared`.
struct CommitProof {
    uint256 chainId;
    uint256 blockOrBatchNumber;
    uint256 messageIndex;
    L2Message message;
    bytes32[] merkleProof;
}

/// @notice Per-chain L1→L2 dispatch parameters for `executeFlow` / `revertFlow`. The
/// caller picks gas + refund settings per chain; `mintValue` is what's passed to
/// `Bridgehub.requestL2TransactionDirect` as the L2 base token mint amount, and must
/// collectively sum to `msg.value` for ETH-base chains.
struct ExecuteParams {
    uint256 mintValue;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
}

/// @notice On-chain flow lifecycle states.
enum FlowState {
    None,
    Initiated,
    Finalized,
    Reverted
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1-side flow coordinator. Owns flow lifecycle, verifies per-chain commit logs
/// against the existing L1 `IMessageVerification`, and dispatches L1→L2 priority txs via
/// `Bridgehub` to authorize per-chain settlement (or refunds).
///
/// `flowId` is a cryptographic commitment to the full spec set:
/// `keccak256(abi.encode(sortedSpecHashes))`. `recordFinalitySignal` enforces equality
/// between the registered `flowId` and the hash of the verified commits' spec hashes; this
/// catches partial-commit attacks (e.g., one side of a swap not committing) without any
/// count-based heuristic.
///
/// The escrow address per participating L2 is registered up-front: the linker's one-shot
/// `initialize` populates a `chainId -> escrowAddress` map. Commit-log validation checks
/// each log's sender equals the escrow registered for that chain. This removes the older
/// "single canonical address everywhere" assumption — useful when different L2s have
/// non-matching deployment quirks (different ContractDeployer, nonce constraints, etc.).
interface IL1FlowLinker {
    event FlowRegistered(bytes32 indexed flowId, address indexed registrar, uint64 deadline);
    event FlowFinalized(bytes32 indexed flowId);
    event FlowReverted(bytes32 indexed flowId);
    event FlowExecuteDispatched(bytes32 indexed flowId, uint256 indexed chainId, bytes32 canonicalTxHash);
    event FlowRefundDispatched(bytes32 indexed flowId, uint256 indexed chainId, bytes32 canonicalTxHash);

    /// @notice One-shot post-deploy setup. Registers the escrow address for each chain the
    /// linker may coordinate. `_chainIds` and `_escrows` are parallel arrays of equal
    /// length; the caller is responsible for sorting/uniqueness. Subsequent calls revert.
    function initialize(uint256[] calldata _chainIds, address[] calldata _escrows) external;

    /// @notice Returns the L2 escrow address registered for `_chainId`, or `address(0)` if
    /// the chain was never registered.
    function escrowOf(uint256 _chainId) external view returns (address);

    /// @notice Register a flow on L1. `_chainIds` MUST be sorted ascending and deduplicated.
    /// `_flowId` is the `keccak256(abi.encode(sortedSpecHashes))` the participants agreed on
    /// off-chain; the linker doesn't know the specs yet — only that this flowId stands for
    /// a specific bundle of them.
    function registerFlow(bytes32 _flowId, uint256[] calldata _chainIds, uint64 _deadline) external;

    /// @notice Verify the commit logs, assert completeness against `_flowId`, check graph
    /// closure, and flip the flow to `Finalized`. Completeness check:
    /// `keccak256(abi.encode(sortedSpecHashes)) == _flowId`. The `_proofs` array is in the
    /// order the caller chose; the linker sorts the extracted spec hashes itself before
    /// hashing.
    function recordFinalitySignal(bytes32 _flowId, CommitProof[] calldata _proofs) external;

    /// @notice Dispatch one `Bridgehub.requestL2TransactionDirect` per participating chain,
    /// targeting that chain's registered escrow (see `escrowOf`) with payload
    /// `authorizeFromL1(flowId, specHashes)`. The hashes sent to chain `X` are the union of
    /// (a) hashes whose source is `X` (committed there) and (b) hashes whose destination is
    /// `X`. `msg.value` must equal sum of `_execParams[i].mintValue`.
    function executeFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable;

    /// @notice After deadline with no finality, dispatch
    /// `authorizeRefundFromL1(flowId, specHashes)` to each chain that committed at least
    /// one spec. Chains that committed nothing receive no dispatch (their `_execParams`
    /// entry must have `mintValue == 0`). Caller of `revertFlow` pays gas; `msg.value`
    /// rules match `executeFlow`.
    function revertFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable;

    function flowState(bytes32 _flowId) external view returns (FlowState);
}

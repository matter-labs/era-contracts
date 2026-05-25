// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {L2Message} from "../common/Messaging.sol";
import {FlowState, Participant, SendSpec} from "./IDummyFlow.sol";

/// @notice Inclusion proof bundle for one chain's commit log. The linker re-verifies each via
/// `IMessageVerification.proveL2MessageInclusionShared`.
struct CommitProof {
    uint256 chainId;
    uint256 blockOrBatchNumber;
    uint256 messageIndex;
    L2Message message;
    bytes32[] merkleProof;
}

/// @notice Per-chain L1→L2 dispatch parameters for `executeFlow`. The caller picks gas + refund
/// settings per chain; `mintValue` is what's passed to `Bridgehub.requestL2TransactionDirect`
/// as the L2 base token mint amount, and must collectively sum to `msg.value` for ETH-base
/// chains.
struct ExecuteParams {
    uint256 mintValue;
    uint256 l2GasLimit;
    uint256 l2GasPerPubdataByteLimit;
    address refundRecipient;
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice L1-side flow coordinator. Owns flow lifecycle (Initiated → Finalized → Reverted),
/// verifies per-chain commit logs against each chain's batch root via the existing L1 message
/// verification path, and drives finality by dispatching one L1→L2 priority tx per participating
/// chain to that chain's `L2FlowEscrow`.
interface IL1FlowLinker {
    event FlowRegistered(bytes32 indexed flowId, address indexed registrar, uint64 deadline);
    event FlowFinalized(bytes32 indexed flowId);
    event FlowReverted(bytes32 indexed flowId);
    event FlowExecuteDispatched(bytes32 indexed flowId, uint256 indexed chainId, bytes32 canonicalTxHash);
    event FlowRefundDispatched(bytes32 indexed flowId, uint256 indexed chainId, bytes32 canonicalTxHash);

    /// @notice Register a flow on L1 with its full participating set. `msg.sender` is recorded
    /// as the registrar (currently informational — anyone can drive `recordFinalitySignal` and
    /// `executeFlow`). One registration per flow id. Must include at least one participant.
    function registerFlow(bytes32 _flowId, Participant[] calldata _participants, uint64 _deadline) external;

    /// @notice Verify one commit log per non-receive-only participant against its chain's L1
    /// batch root, check graph closure (every `destChainId` referenced is in the participating
    /// set), and flip the flow to `Finalized`. Receive-only chains are not required to publish
    /// a commit log — they trust the linker's L1→L2 dispatch.
    function recordFinalitySignal(bytes32 _flowId, CommitProof[] calldata _proofs) external;

    /// @notice After finality, dispatch one `Bridgehub.requestL2TransactionDirect` per
    /// participating chain. Each chain receives the list of `SendSpec`s whose `destChainId`
    /// equals its own (its inbound set), encoded as a call to the chain's escrow
    /// `executeFromL1(_flowId, inboundSpecs)`. `msg.value` must equal the sum of
    /// `_execParams[i].mintValue` for ETH-base chains.
    function executeFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable;

    /// @notice After the deadline, if the flow never finalized, dispatch `refundFromL1` to
    /// every chain that committed a lock so depositors can recover their tokens. Receive-only
    /// chains are skipped automatically. `msg.value` rules match `executeFlow`.
    function revertFlow(bytes32 _flowId, ExecuteParams[] calldata _execParams) external payable;

    function flowState(bytes32 _flowId) external view returns (FlowState);
}

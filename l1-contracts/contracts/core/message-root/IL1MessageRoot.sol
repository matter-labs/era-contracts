// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

/**
 * @author Matter Labs
 * @notice MessageRoot contract is responsible for storing and aggregating the roots of the batches from different chains into the MessageRoot.
 * @custom:security-contact security@matterlabs.dev
 */
interface IL1MessageRoot {
    /// @notice Governance enabled interop for the chain.
    event InteropEnabled(uint256 indexed chainId);

    /// @notice `sender` may, or may no longer, send this chain's local messages.
    event LocalMessageSenderSet(address indexed sender, bool allowed);

    /// @notice `sender` sent a local message with data hash `messageHash`, the only message of this chain's batch
    /// `batchNumber`.
    event LocalMessageSent(address indexed sender, uint256 indexed batchNumber, bytes32 messageHash);

    function v31UpgradeChainBatchNumber(uint256 _chainId) external view returns (uint256);

    /// @notice Whether `_sender` may send this chain's local messages.
    /// See {protocol-docs/message-root.md#local-messages}.
    function isLocalMessageSender(address _sender) external view returns (bool);

    /// @notice Allows or disallows `_sender` to send this chain's local messages. Callable by the Bridgehub owner
    /// and by the upgrade authority. See {protocol-docs/message-root.md#local-messages}.
    /// @param _sender The local message sender.
    /// @param _allowed Whether it may send.
    function setLocalMessageSender(address _sender, bool _allowed) external;

    /// @notice Records a message of this chain, sent by the caller, as the next batch of this chain's own slot in
    /// the shared tree. Callable by the allowed local message senders.
    /// See {protocol-docs/message-root.md#local-messages}.
    /// @param _messageHash The keccak256 hash of the message's data.
    /// @return batchNumber This chain's batch number that holds the message.
    function sendLocalMessage(bytes32 _messageHash) external returns (uint256 batchNumber);

    /// @notice Enables interop for a chain. One-way: there is no way to disable it. Callable by the
    /// Bridgehub owner, once the chain is no longer pending its balance backfill.
    /// See {protocol-docs/interop-gating.md#enabling-interop}.
    /// @param _chainId The chain to enable interop for.
    /// @param _requireSecondProofSystem Whether the chain must permanently require its second proof system and be
    /// in multi-proof mode.
    function enableInterop(uint256 _chainId, bool _requireSecondProofSystem) external;

    /// @notice Returns whether governance enabled interop for the chain; false for unknown chains.
    /// See {protocol-docs/interop-gating.md}.
    /// @param _chainId The chain to query.
    function isInteropEnabled(uint256 _chainId) external view returns (bool);
}

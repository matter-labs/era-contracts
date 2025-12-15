// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.20;

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for sending arbitrary length messages to L1
 * @dev by default ZkSync can send fixed-length messages on L1.
 * A fixed length message has 4 parameters `senderAddress`, `isService`, `key`, `value`,
 * the first one is taken from the context, the other three are chosen by the sender.
 * @dev To send a variable-length message we use this trick:
 * - This system contract accepts an arbitrary length message and sends a fixed length message with
 * parameters `senderAddress == this`, `isService == true`, `key == msg.sender`, `value == keccak256(message)`.
 * - The contract on L1 accepts all sent messages and if the message came from this system contract
 * it requires that the preimage of `value` be provided.
 */
interface IL2ToL1MessengerZKSyncOS {
    /// @notice L2 event emitted to track L1 messages.
    event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);

    /// @notice Sends an arbitrary length message to L1.
    /// @param _message The variable length message to be sent to L1.
    /// @return Returns the keccak256 hashed value of the message.
    function sendToL1(bytes calldata _message) external returns (bytes32);
}

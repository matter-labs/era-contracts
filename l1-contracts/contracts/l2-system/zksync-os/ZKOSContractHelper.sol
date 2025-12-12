// SPDX-License-Identifier: MIT
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
interface IL1Messenger {
    /// @notice L2 event emitted to track L1 messages.
    event L1MessageSent(address indexed _sender, bytes32 indexed _hash, bytes _message);

    /// @notice Sends an arbitrary length message to L1.
    /// @param _message The variable length message to be sent to L1.
    /// @return Returns the keccak256 hashed value of the message.
    function sendToL1(bytes calldata _message) external returns (bytes32);
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IMailbox {
    function finalizeEthWithdrawal(
        uint256 _l2BatchNumber,
        uint256 _l2MessageIndex,
        uint16 _l2TxNumberInBlock,
        bytes calldata _message,
        bytes32[] calldata _merkleProof
    ) external;
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Interface for the contract that is used to simulate Base Token on L2.
 */
interface IBaseToken {
    /// @notice Allows the withdrawal of Base Token to a given L1 receiver.
    /// @param _l1Receiver The address on L1 to receive the withdrawn Base Token.
    function withdraw(address _l1Receiver) external payable;

    /// @notice Allows the withdrawal of Base Token to a given L1 receiver along with an additional message.
    /// @param _l1Receiver     The address on L1 to receive the withdrawn Base Token.
    /// @param _additionalData Additional message or data to be sent alongside the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes memory _additionalData) external payable;

    /// @notice Emitted when a base-token withdrawal is initiated.
    /// @param _l2Sender    The L2 address that initiated the withdrawal.
    /// @param _l1Receiver  The L1 address that will receive the withdrawn Base Token.
    /// @param _amount      The amount of Base Token (in wei) withdrawn.
    event Withdrawal(address indexed _l2Sender, address indexed _l1Receiver, uint256 _amount);

    /// @notice Emitted when a base-token withdrawal with an additional message is initiated.
    /// @param _l2Sender       The L2 address that initiated the withdrawal.
    /// @param _l1Receiver     The L1 address that will receive the withdrawn Base Token.
    /// @param _amount         The amount of Base Token (in wei) withdrawn.
    /// @param _additionalData Arbitrary data/message forwarded alongside the withdrawal.
    event WithdrawalWithMessage(
        address indexed _l2Sender,
        address indexed _l1Receiver,
        uint256 _amount,
        bytes _additionalData
    );
}

uint160 constant SYSTEM_HOOKS_OFFSET = 0x7000;
address constant COMPLEX_UPGRADER_SYSTEM_CONTRACT = address(SYSTEM_CONTRACTS_OFFSET + 0x0f);
address constant L1_MESSENGER_HOOK = address(SYSTEM_HOOKS_OFFSET + 0x01);
address constant SET_BYTECODE_ON_ADDRESS_HOOK = address(SYSTEM_HOOKS_OFFSET + 0x02);
uint160 constant SYSTEM_CONTRACTS_OFFSET = 0x8000; // 2^15
IL1Messenger constant L2_MESSENGER = IL1Messenger(address(SYSTEM_CONTRACTS_OFFSET + 0x08));

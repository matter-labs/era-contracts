// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1_MESSENGER_HOOK, IL1Messenger} from "./L2ContractHelper.sol";
import {L1MessengerHookFailed, NotEnoughGasSupplied, NotSelfCall} from "./errors/L2ContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for sending arbitrary length messages to L1
 * @dev by default ZkSync can send fixed length messages on L1.
 * A fixed length message has 4 parameters `senderAddress` `isService`, `key`, `value`,
 * the first one is taken from the context, the other three are chosen by the sender.
 * @dev To send a variable length message we use this trick:
 * - This system contract accepts a arbitrary length message and sends a fixed length message with
 * parameters `senderAddress == this`, `marker == true`, `key == msg.sender`, `value == keccak256(message)`.
 * - The contract on L1 accepts all sent messages and if the message came from this system contract
 * it requires that the preimage of `value` be provided.
 */
contract L1Messenger is IL1Messenger {
    uint256 private constant SHA3 = 30;
    uint256 private constant SHA3WORD = 6;
    uint256 private constant LOG = 375;
    uint256 private constant LOGDATA = 8;
    uint256 private constant L2_TO_L1_LOG_SERIALIZE_SIZE = 88;

    function ceilDiv(uint256 x, uint256 y) internal pure returns (uint256) {
        return (x + y - 1) / y;
    }

    /// @dev Exact Solidity equivalent of `keccak256_ergs_cost(len) / ERGS_PER_GAS` in ZKsync OS
    function gasKeccak(uint256 len) internal pure returns (uint256) {
        uint256 words = ceilDiv(len, 32);
        return SHA3 + SHA3WORD * words;
    }

    /// @dev Exact Solidity equivalent of l1_message_ergs_cost / ERGS_PER_GAS in ZKsync OS
    function estimateL1MessageGas(uint256 messageLen) internal pure returns (uint256) {
        uint256 hashing = gasKeccak(L2_TO_L1_LOG_SERIALIZE_SIZE) + gasKeccak(64) * 3 + gasKeccak(messageLen);

        uint256 logCost = LOG + LOGDATA * messageLen;

        return hashing + logCost;
    }

    function burnGas(bytes calldata _message) internal {
        uint256 gasToBurn = estimateL1MessageGas(_message.length);

        // If not enough gas to burn the desired amount, revert with your custom error
        if (gasleft() <= gasToBurn) {
            revert NotEnoughGasSupplied();
        }

        (bool success, ) = address(this).call{gas: gasToBurn}("");
        success; // ignored
    }

    /// @notice Public functionality to send messages to L1.
    /// @param _message The message intended to be sent to L1.
    function sendToL1(bytes calldata _message) external returns (bytes32 hash) {
        // As a first step we burn the respective amount of gas, which is the explicit cost of sending L2->L1 message.
        burnGas(_message);

        // Call system hook at the known system address.
        // Calldata to the hook is exactly `message`.
        (bool ok, ) = L1_MESSENGER_HOOK.call(abi.encodePacked(msg.sender, _message));
        require(ok, L1MessengerHookFailed());
        hash = keccak256(_message);

        emit L1MessageSent(msg.sender, hash, _message);
    }

    // --- Burner entrypoint: only callable by self ---
    fallback() payable external {
        // This fallback is used *only* for self-call burning
        require(msg.sender == address(this), NotSelfCall());
        assembly {
            invalid()
        }
    }
}

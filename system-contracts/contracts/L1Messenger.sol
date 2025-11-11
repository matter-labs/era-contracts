// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1Messenger} from "./interfaces/IL1Messenger.sol";

import {L1_MESSENGER_HOOK} from "./Constants.sol";
import {L1MessengerHookFailed} from "./SystemContractErrors.sol";

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
contract L1Messenger is IL1Messenger, SystemContractBase {
    /// @notice Public functionality to send messages to L1.
    /// @param _message The message intended to be sent to L1.
    function sendToL1(bytes calldata _message) external override returns (bytes32 hash) {
        // Call system hook at the known system address.
        // Calldata to the hook is exactly `message`.
        (bool ok, bytes memory ret) = L1_MESSENGER_HOOK.call(_message);
        if (!ok || ret.length != 32) {
            revert(L1MessengerHookFailed);
        }
        hash = bytes32(ret);
    }
}

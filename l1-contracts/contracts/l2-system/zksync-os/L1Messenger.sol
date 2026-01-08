// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L1_MESSENGER_HOOK} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IL2ToL1MessengerZKSyncOS} from "contracts/common/l2-helpers/IL2ToL1MessengerZKSyncOS.sol";
import {L1MessengerHookFailed, NotEnoughGasSupplied, NotSelfCall} from "./errors/ZKOSContractErrors.sol";
import {L1MessageGasLib} from "./L1MessageGasLib.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Smart contract for sending arbitrary length messages to L1
 * @dev by default ZKsync can send fixed length messages on L1.
 * A fixed length message has 4 parameters `senderAddress` `isService`, `key`, `value`,
 * the first one is taken from the context, the other three are chosen by the sender.
 * @dev To send a variable length message we use this trick:
 * - This system contract accepts a arbitrary length message and sends a fixed length message with
 * parameters `senderAddress == this`, `marker == true`, `key == msg.sender`, `value == keccak256(message)`.
 * - The contract on L1 accepts all sent messages and if the message came from this system contract
 * it requires that the preimage of `value` be provided.
 */
contract L1Messenger is IL2ToL1MessengerZKSyncOS {
    function burnGas(bytes calldata _message) internal {
        uint256 gasToBurn = L1MessageGasLib.estimateL1MessageGas(_message.length);

        // If not enough gas to burn the desired amount, revert
        if ((gasleft() * 63) / 64 < gasToBurn) {
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
    // slither-disable-next-line locked-ether
    fallback() external payable {
        // This fallback is used *only* for self-call burning
        // Any ETH sent here is intentionally burned and cannot be withdrawn
        require(msg.sender == address(this), NotSelfCall());
        assembly {
            invalid()
        }
    }
}

// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockL1MessengerHook
/// @notice Mock for the ZK-VM L1_MESSENGER_HOOK (address 0x7001).
/// @dev In production, this hook records the L2→L1 message in the ZK-VM state.
/// On Anvil, we just return success — the L1MessageSent event from L1MessengerZKOS
/// is sufficient for the test infrastructure to capture and process messages.
contract MockL1MessengerHook {
    fallback() external payable {
        // No-op: Anvil test infrastructure reads L1MessageSent events directly
    }

    receive() external payable {}
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2ToL1Messenger} from "./interfaces/IL2ToL1Messenger.sol";

/// @dev Offset used to pull Address values from stack
uint256 constant SYSTEM_CONTRACTS_OFFSET = 0x8000;

/// @dev The address of the L2 to L1 messenger system contract
address constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR = address(uint160(SYSTEM_CONTRACTS_OFFSET + 0x08));

/// @dev The L2 to L1 messenger system contract instance
IL2ToL1Messenger constant L2_TO_L1_MESSENGER_SYSTEM_CONTRACT = IL2ToL1Messenger(
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR
);

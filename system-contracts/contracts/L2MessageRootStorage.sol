// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Unauthorized} from "./SystemContractErrors.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Nullifer contract for L2->L2 txs.
 * @dev
 */
contract L2MessageRootStorage {
    /// @notice The balances of the users.
    mapping(bytes32 txHash => bool alreadyExecuted) internal alreadyExecuted;

    function markAsExecuted(bytes32 txHash) external {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        // solhint-disable-next-line gas-custom-errors
        require(!alreadyExecuted[txHash], "L2N: Already executed");
        alreadyExecuted[txHash] = true;
    }
}

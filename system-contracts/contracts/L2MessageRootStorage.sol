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
    mapping(bytes32 txHash => bool alreadyExecuted) public alreadyExecuted;

    mapping(uint256 chainId => mapping(uint256 blockNumber => bytes32 msgRoot)) public msgRoots;

    function markAsExecuted(bytes32 _txHash) external {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        // solhint-disable-next-line gas-custom-errors
        require(!alreadyExecuted[_txHash], "L2N: Already executed");
        alreadyExecuted[_txHash] = true;
    }

    function addMessageRoot(uint256 chainId, uint256 blockNumber, bytes32 msgRoot) external {
        msgRoots[chainId][blockNumber] = msgRoot;
    }
}

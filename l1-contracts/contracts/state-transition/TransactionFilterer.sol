// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {ITransactionFilterer} from "./chain-interfaces/ITransactionFilterer.sol";

/**
 * @title Minimal Transaction Filterer using AccessControl
 * @notice All calls to CONTRACT_DEPLOYER will be blocked
 */
contract TransactionFilterer is ITransactionFilterer {
    // Whitelist role for L2 contracts
    bytes32 public constant WHITELISTED_ROLE = keccak256("WHITELISTED_ROLE");
    address public constant CONTRACT_DEPLOYER_ADDRESS = 0x0000000000000000000000000000000000008006;

    /**
     * @notice Check if the transaction is allowed.
     * @dev This minimal implementation verifies that we aren't calling ContracDeployer
     */
    function isTransactionAllowed(
        address /* sender */,
        address contractL2,
        uint256 /* mintValue */,
        uint256 /* l2Value */,
        bytes memory /* l2Calldata */,
        address /* refundRecipient */
    ) external view override returns (bool) {
        // Allow all transactions that are NOT contract deployments
        if (contractL2 != CONTRACT_DEPLOYER_ADDRESS) {
            return true;
        }
        return false;
    }
}

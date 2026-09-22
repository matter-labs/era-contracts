// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-v4/access/AccessControl.sol";
import {ITransactionFilterer} from "./chain-interfaces/ITransactionFilterer.sol";

/**
 * @title Permissioned Transaction Filterer
 * @notice All calls are blocked unless the target contract has the WHITELISTED_ROLE,
 *         or the sender has the SUPERUSER_ROLE.
 */
contract AccessControlledTransactionFilterer is ITransactionFilterer, AccessControl {
    /// @notice Role for contracts allowed to receive L2 transactions
    bytes32 public constant WHITELISTED_ROLE = keccak256("WHITELISTED_ROLE");
    /// @notice Role for privileged senders who can bypass whitelist checks
    bytes32 public constant SUPERUSER_ROLE = keccak256("SUPERUSER_ROLE");

    /**
     * @dev Grant the DEFAULT_ADMIN_ROLE to the deployer so they can manage roles.
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Check if the transaction is allowed.
     * @dev Allowed if:
     *      - `contractL2` has WHITELISTED_ROLE, or
     *      - `sender` has SUPERUSER_ROLE.
     */
    function isTransactionAllowed(
        address sender,
        address contractL2,
        uint256 /* mintValue */,
        uint256 /* l2Value */,
        bytes memory /* l2Calldata */,
        address /* refundRecipient */
    ) external view override returns (bool) {
        return hasRole(WHITELISTED_ROLE, contractL2) || hasRole(SUPERUSER_ROLE, sender);
    }
}

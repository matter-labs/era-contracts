// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import "@openzeppelin/contracts-v4/access/AccessControl.sol";
import {ITransactionFilterer} from "./chain-interfaces/ITransactionFilterer.sol";

/**
 * @title Permissioned Transaction Filterer
 * @notice All calls to the Contract Deployer are blocked.
 *         Other addresses must have the WHITELISTED_ROLE to be allowed.
 */
contract AccessControlledTransactionFilterer is ITransactionFilterer, AccessControl {
    // Whitelist role for L2 contracts
    bytes32 public constant WHITELISTED_ROLE = keccak256("WHITELISTED_ROLE");

    /**
     * @dev Grant the DEFAULT_ADMIN_ROLE to the deployer so they can manage roles.
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
    }

    /**
     * @notice Check if the transaction is allowed.
     * @dev The transaction is allowed only if:
     *      1) contractL2 is not the special Contract Deployer address, AND
     *      2) contractL2 has the WHITELISTED_ROLE.
     */
    function isTransactionAllowed(
        address /* sender */,
        address contractL2,
        uint256 /* mintValue */,
        uint256 /* l2Value */,
        bytes memory /* l2Calldata */,
        address /* refundRecipient */
    ) external view override returns (bool) {
        // Only allow calls if contractL2 has been explicitly granted WHITELISTED_ROLE
        return hasRole(WHITELISTED_ROLE, contractL2);
    }
}

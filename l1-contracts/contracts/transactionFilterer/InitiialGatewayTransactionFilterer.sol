// SPDX-License-Identifier: MIT
pragma solidity ^0.8.21;

import {Ownable2Step} from "@openzeppelin/contracts-v4/access/Ownable2Step.sol";
import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";

/// @title Initial Gateway Transaction Filterer
/// @notice Filters L1 -> L2 gateway transactions by whitelisting the L1 sender.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
contract InitiialGatewayTransactionFilterer is ITransactionFilterer, Ownable2Step {
    /// @notice Mapping of L1 senders that are allowed to initiate transactions.
    mapping(address => bool) public whitelistedSenders;

    /// @notice Emitted when a sender address is added to the whitelist.
    /// @param sender The address being whitelisted.
    event SenderWhitelisted(address indexed sender);

    /// @notice Emitted when a sender address is removed from the whitelist.
    /// @param sender The address being un‑whitelisted.
    event SenderUnWhitelisted(address indexed sender);

    /// @notice Deploy the filterer and set the initial owner.
    /// @param initialOwner The address that will become the contract owner.
    constructor(address initialOwner) {
        require(initialOwner != address(0), "Owner cannot be zero address");
        _transferOwnership(initialOwner);
    }

    /// @notice Add or remove an address from the sender whitelist.
    /// @dev Only callable by the contract owner.
    /// @param sender The address whose status is being updated.
    /// @param status `true` to whitelist, `false` to un‑whitelist.
    function setSenderWhitelist(address sender, bool status) external onlyOwner {
        require(sender != address(0), "Sender is zero address");
        whitelistedSenders[sender] = status;

        if (status) {
            emit SenderWhitelisted(sender);
        } else {
            emit SenderUnWhitelisted(sender);
        }
    }

    /// @inheritdoc ITransactionFilterer
    function isTransactionAllowed(
        address sender,
        address /* contractL2 */,
        uint256 /* mintValue */,
        uint256 /* l2Value */,
        bytes calldata /* l2Calldata */,
        address /* refundRecipient */
    ) external view override returns (bool) {
        return whitelistedSenders[sender];
    }
}

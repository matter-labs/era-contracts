// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ITransactionFilterer} from "../state-transition/chain-interfaces/ITransactionFilterer.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A transaction filterer that rejects every L1->L2 transaction.
/// @dev Installed on a chain before it is shut down, so that no deposits or other L1->L2 transactions
/// can be requested for it, including through the legacy Era `Mailbox.requestL2Transaction`.
/// It does not cover service transactions, which skip the filterer, see `L1AssetTracker.shutdownChain`.
contract DenyAllTransactionFilterer is ITransactionFilterer {
    /// @inheritdoc ITransactionFilterer
    function isTransactionAllowed(
        address, // _sender
        address, // _contractL2
        uint256, // _mintValue
        uint256, // _l2Value
        bytes calldata, // _l2Calldata
        address // _refundRecipient
    ) external pure returns (bool) {
        return false;
    }
}

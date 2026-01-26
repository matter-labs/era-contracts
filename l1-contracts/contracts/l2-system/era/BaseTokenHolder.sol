// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBaseTokenHolder} from "../../common/l2-helpers/IBaseTokenHolder.sol";
import {L2_BOOTLOADER_ADDRESS, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_INTEROP_HANDLER} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolder
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice A contract that holds the base token reserves for the chain.
 * @dev This contract replaces the mint/burn approach with a transfer-based approach for better EVM compatibility.
 *
 * ## Design Rationale
 *
 * Instead of minting base tokens during deposits and interops, tokens are transferred from this holder contract.
 * This makes the system more compatible with standard EVM tooling like Foundry, as all tooling supports
 * that some contract receives "value" from another contract.
 *
 * ## Balance Invariant
 *
 * The total sum of balances across all contracts on the chain equals 2^127 - 1.
 * This holder's balance = 2^127 - 1 - <total deposited to chain>.
 *
 * ## Initial Balance
 *
 * During migration, this contract is initialized with 2^127 - 1 base tokens.
 * This is sufficient for any reasonable base token, as no token has a total supply greater than 2^127.
 *
 * ## Overflow/Underflow Prevention
 *
 * - Overflow: Before any user receives base tokens, this contract loses the same amount.
 *   Thus, no balance can overflow.
 * - Underflow: The chain operator must ensure the base token's total supply is below 2^127.
 *   This is true for all known tokens including meme coins.
 */
contract BaseTokenHolder is IBaseTokenHolder {
    /// @notice Modifier that restricts access to the bootloader or InteropHandler.
    modifier onlyAuthorizedCaller() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS && msg.sender != address(L2_INTEROP_HANDLER)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev This replaces the mint operation. Tokens are transferred from this contract's balance.
    /// @dev The actual transfer is done via L2BaseToken.transferFromTo to maintain balance consistency.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external override onlyAuthorizedCaller {
        if (_amount == 0) {
            return;
        }

        // Transfer base tokens from this holder to the recipient
        // This uses the L2BaseToken's transferFromTo which handles balance updates
        L2_BASE_TOKEN_SYSTEM_CONTRACT.transferFromTo(address(this), _to, _amount);
    }

    /// @notice Fallback to accept base token transfers from InteropHandler only.
    /// @dev Restricts token reception to prevent accidental transfers.
    receive() external payable {
        if (msg.sender != address(L2_INTEROP_HANDLER)) {
            revert Unauthorized(msg.sender);
        }
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBaseTokenHolder} from "./interfaces/IBaseTokenHolder.sol";
import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {BOOTLOADER_FORMAL_ADDRESS, BASE_TOKEN_SYSTEM_CONTRACT} from "./Constants.sol";
import {Unauthorized} from "./SystemContractErrors.sol";

/**
 * @title BaseTokenHolder
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice A system contract that holds the base token reserves for the chain.
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
 * The total sum of balances across all contracts on the chain equals 2^256 - 1.
 * This holder's balance = 2^256 - 1 - <total deposited to chain>.
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
 * - Underflow: The chain operator must ensure the base token's total supply is below 2^128.
 *   This is true for all known tokens including meme coins.
 */
contract BaseTokenHolder is IBaseTokenHolder, SystemContractBase {
    /// @notice Modifier that restricts access to bootloader or InteropHandler.
    modifier onlyAuthorizedCaller() {
        // Note: We use the same authorization as L2BaseToken.mint
        // This includes bootloader and InteropHandler
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            // Check if it's the InteropHandler by using the same pattern as SystemContractBase
            // The InteropHandler check is handled by onlyCallFromBootloaderOrInteropHandler in L2BaseToken
            // For BaseTokenHolder, we allow calls from bootloader only initially
            // InteropHandler will call L2BaseToken which will call this contract via transferFromTo
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
        BASE_TOKEN_SYSTEM_CONTRACT.transferFromTo(address(this), _to, _amount);

        emit BaseTokenGiven(_to, _amount);
    }

    /// @notice Receives base tokens back into the holder.
    /// @dev This replaces the burn operation. Tokens are transferred back to this contract.
    /// @dev The msg.value is automatically added to this contract's balance by the system.
    function receive_() external payable override {
        // The base tokens are already transferred to this contract via msg.value
        // We just need to emit the event for tracking
        if (msg.value > 0) {
            emit BaseTokenReceived(msg.sender, msg.value);
        }
    }

    /// @notice Fallback to accept base token transfers.
    /// @dev This allows the contract to receive base tokens directly.
    receive() external payable {
        if (msg.value > 0) {
            emit BaseTokenReceived(msg.sender, msg.value);
        }
    }
}

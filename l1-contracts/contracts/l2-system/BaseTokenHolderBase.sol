// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBaseTokenHolder} from "../common/l2-helpers/IBaseTokenHolder.sol";
import {L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolderBase
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Abstract base contract that holds the base token reserves for the chain.
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
// slither-disable-next-line locked-ether
abstract contract BaseTokenHolderBase is IBaseTokenHolder {
    /// @notice Modifier that restricts access to the InteropHandler only.
    modifier onlyInteropHandler() {
        if (msg.sender != address(L2_INTEROP_HANDLER)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that restricts access to trusted senders that can send base tokens to this contract.
    /// @dev InteropHandler: returns burned tokens during interop operations
    /// @dev InteropCenter: returns burned tokens during batch interop operations
    /// @dev NativeTokenVault: returns tokens during bridged base token burns
    modifier onlyTrustedSender() {
        if (
            msg.sender != address(L2_INTEROP_HANDLER) &&
            msg.sender != L2_INTEROP_CENTER_ADDR &&
            msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR
        ) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev This replaces the mint operation. Tokens are transferred from this contract's balance.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external override onlyInteropHandler {
        if (_amount == 0) {
            return;
        }

        _transferTo(_to, _amount);
    }

    /// @notice Internal function to transfer base tokens to a recipient.
    /// @dev Must be implemented by derived contracts based on the chain type (Era vs ZK OS).
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to transfer.
    function _transferTo(address _to, uint256 _amount) internal virtual;

    /// @notice Fallback to accept base token transfers from trusted senders.
    /// @dev Accepts transfers from InteropHandler, InteropCenter, and NativeTokenVault for token burn operations.
    receive() external payable onlyTrustedSender {}
}

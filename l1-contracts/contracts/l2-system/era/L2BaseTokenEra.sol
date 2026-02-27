// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2BaseTokenBase} from "../L2BaseTokenBase.sol";
import {IL2BaseTokenEra} from "./interfaces/IL2BaseTokenEra.sol";
import {L2_BASE_TOKEN_HOLDER_ADDR, L2_BOOTLOADER_ADDRESS, L2_DEPLOYER_SYSTEM_CONTRACT_ADDR, MSG_VALUE_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {L2_ASSET_TRACKER} from "../../common/l2-helpers/L2ContractInterfaces.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "../../common/Config.sol";
import {InsufficientFunds, Unauthorized} from "../../common/L1ContractErrors.sol";

/**
 * @title L2BaseTokenEra
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Native ETH contract for Era chains.
 * @dev It does NOT provide interfaces for personal interaction with tokens like `transfer`, `approve`, and `transferFrom`.
 * Instead, this contract is used by the bootloader and `MsgValueSimulator`/`ContractDeployer` system contracts
 * to perform the balance changes while simulating the `msg.value` Ethereum behavior.
 */
contract L2BaseTokenEra is L2BaseTokenBase, IL2BaseTokenEra {
    /// @notice Modifier that makes sure that the method can only be called from the bootloader.
    modifier onlyBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Returns the total circulating supply of base tokens.
    /// @dev Computed as: INITIAL_BASE_TOKEN_HOLDER_BALANCE - current holder balance
    /// @dev This replaces the previous storage-based totalSupply that was incremented on mint.
    /// @dev This formula is safe because selfdestruct is not supported on Era, so no funds can be force-sent to BaseTokenHolder.
    function totalSupply() external view override returns (uint256) {
        return INITIAL_BASE_TOKEN_HOLDER_BALANCE - eraAccountBalance[L2_BASE_TOKEN_HOLDER_ADDR];
    }

    /// @notice Transfer tokens from one address to another.
    /// @param _from The address to transfer the ETH from.
    /// @param _to The address to transfer the ETH to.
    /// @param _amount The amount of ETH in wei being transferred.
    /// @dev This function can be called only by trusted system contracts.
    /// @dev This function also emits "Transfer" event, which might be removed later on.
    function transferFromTo(address _from, address _to, uint256 _amount) external override {
        if (
            msg.sender != MSG_VALUE_SYSTEM_CONTRACT &&
            msg.sender != L2_DEPLOYER_SYSTEM_CONTRACT_ADDR &&
            msg.sender != L2_BOOTLOADER_ADDRESS &&
            msg.sender != L2_BASE_TOKEN_HOLDER_ADDR
        ) {
            revert Unauthorized(msg.sender);
        }

        uint256 fromBalance = eraAccountBalance[_from];
        if (fromBalance < _amount) {
            revert InsufficientFunds(_amount, fromBalance);
        }
        unchecked {
            eraAccountBalance[_from] = fromBalance - _amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            eraAccountBalance[_to] += _amount;
        }

        emit Transfer(_from, _to, _amount);
    }

    /// @notice Returns ETH balance of an account
    /// @dev It takes `uint256` as an argument to be able to properly simulate the behaviour of the
    /// Ethereum's `BALANCE` opcode that accepts uint256 as an argument and truncates any upper bits
    /// @param _account The address of the account to return the balance of.
    function balanceOf(uint256 _account) external view override returns (uint256) {
        return eraAccountBalance[address(uint160(_account))];
    }

    /// @notice Increase the balance of the receiver by transferring from BaseTokenHolder.
    /// @dev This method is only callable by the bootloader or InteropHandler.
    /// @dev The totalSupply is now computed from BaseTokenHolder balance, so we only update balances.
    /// @param _account The address which to mint the funds to.
    /// @param _amount The amount of ETH in wei to be minted.
    function mint(address _account, uint256 _amount) external override onlyBootloader {
        // Transfer from BaseTokenHolder to the recipient
        // This decreases holder balance, which increases totalSupply() automatically
        eraAccountBalance[L2_BASE_TOKEN_HOLDER_ADDR] -= _amount;
        eraAccountBalance[_account] += _amount;
        emit Mint(_account, _amount);

        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(_amount);
    }

    /// @notice Initializes the BaseTokenHolder's balance during the V31 upgrade.
    /// @dev Sets the holder balance so that the new computed totalSupply() equals the old value.
    /// @dev Formula: eraAccountBalance[holder] = INITIAL_BASE_TOKEN_HOLDER_BALANCE - __DEPRECATED_totalSupply + eraAccountBalance[holder]
    /// @dev Can only be called by the ComplexUpgrader contract.
    function initializeBaseTokenHolderBalance() external override onlyComplexUpgrader {
        eraAccountBalance[L2_BASE_TOKEN_HOLDER_ADDR] =
            INITIAL_BASE_TOKEN_HOLDER_BALANCE -
            __DEPRECATED_totalSupply +
            eraAccountBalance[L2_BASE_TOKEN_HOLDER_ADDR];
    }
}

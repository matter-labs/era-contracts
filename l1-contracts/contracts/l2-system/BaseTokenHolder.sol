// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {Address} from "@openzeppelin/contracts-v4/utils/Address.sol";

import {IBaseTokenHolder} from "./interfaces/IBaseTokenHolder.sol";
import {L2_ASSET_TRACKER, L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR, L2_INTEROP_CENTER_ADDR, L2_INTEROP_HANDLER, L2_NATIVE_TOKEN_VAULT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";

/**
 * @title BaseTokenHolder
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Contract that holds the base token reserves for the chain.
 * @dev This contract replaces the mint/burn approach with a transfer-based approach for better EVM compatibility.
 *
 * ## Design Rationale
 *
 * Instead of minting base tokens during deposits and interops, tokens are transferred from this holder contract.
 * This makes the system more compatible with standard EVM tooling like Foundry.
 *
 * ## Initial Balance
 *
 * During migration, this contract is initialized with 2^127 - 1 base tokens minus the existing total supply.
 * This is sufficient for any reasonable base token, as no token has a total supply greater than 2^127.
 * The above is only applicable for Era chains, as total supply for ZK OS chains is not tracked (on-chain).
 *
 * ## Overflow/Underflow Prevention
 *
 * - Overflow: Before any user receives base tokens, this contract loses the same amount.
 *   Thus, no balance can overflow.
 * - Underflow: The chain operator must ensure the base token's total supply is below 2^127.
 *   This is true for most popular tokens including meme coins.
 *
 * ## ETH Transfer Events
 *
 * On Era, Transfer events are automatically emitted during any ETH transfer since all transfers
 * go via MsgValueSimulator which calls transferFromTo. On ZK OS, standard ETH transfers work natively.
 * This allows a single implementation to work correctly on both chain types.
 */
// slither-disable-next-line locked-ether
contract BaseTokenHolder is IBaseTokenHolder {
    /// @notice Modifier that restricts access to the InteropHandler only.
    modifier onlyInteropHandler() {
        if (msg.sender != address(L2_INTEROP_HANDLER)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that restricts access to callers that can bridge base tokens.
    /// @dev InteropHandler: returns burned tokens during interop operations
    /// @dev InteropCenter: returns burned tokens during interop operations
    /// @dev NativeTokenVault: returns tokens during bridged base token burns
    /// @dev L2BaseToken: returns burned tokens during withdrawals
    modifier onlyBridgingCaller() {
        if (
            msg.sender != address(L2_INTEROP_HANDLER) &&
            msg.sender != L2_INTEROP_CENTER_ADDR &&
            msg.sender != L2_NATIVE_TOKEN_VAULT_ADDR &&
            msg.sender != L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR
        ) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Modifier that restricts access to L2BaseToken only.
    /// @dev Used for receiving initial balance during initializeBaseTokenHolderBalance.
    modifier onlyL2BaseToken() {
        if (msg.sender != L2_BASE_TOKEN_SYSTEM_CONTRACT_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev This replaces the mint operation. Tokens are transferred from this contract's balance.
    /// @dev NOTE: This is not the only way funds leave this contract:
    /// @dev - On ZK OS, balance is also manipulated directly via storage by the VM.
    /// @dev - On Era, during deposit the bootloader mints base tokens via the mint function in L2BaseToken contract.
    /// @dev WARNING: Since standard ETH transfer is used, the transfer may fail if the recipient
    /// @dev rejects ETH. Only trusted recipients should be used to guarantee successful operation.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external override onlyInteropHandler {
        if (_amount == 0) {
            return;
        }

        Address.sendValue(payable(_to), _amount);
    }

    /// @notice Receives base tokens and initiates bridging by notifying L2AssetTracker.
    /// @dev Called by InteropHandler, InteropCenter, NativeTokenVault, and L2BaseToken during bridging operations.
    /// @dev This function notifies L2AssetTracker to track the bridging operation.
    function burnAndStartBridging() external payable onlyBridgingCaller {
        L2_ASSET_TRACKER.handleInitiateBaseTokenBridgingOnL2(msg.value);
    }

    /// @notice Fallback to accept base token transfers from L2BaseToken only.
    /// @dev Only accepts transfers from L2BaseToken during initializeBaseTokenHolderBalance.
    /// @dev For bridging operations, use burnAndStartBridging() instead.
    receive() external payable onlyL2BaseToken {}
}

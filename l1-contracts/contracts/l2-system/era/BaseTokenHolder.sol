// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBaseTokenHolder} from "../../common/l2-helpers/IBaseTokenHolder.sol";
import {L2_ASSET_TRACKER, L2_BASE_TOKEN_SYSTEM_CONTRACT, L2_INTEROP_HANDLER, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {IMailboxImpl} from "../../state-transition/chain-interfaces/IMailboxImpl.sol";
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
 * ## Withdrawals
 *
 * When users withdraw base tokens to L1, tokens are sent to this contract (increasing its balance,
 * effectively "burning" them from circulation) and an L2->L1 message is sent via L1Messenger.
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
contract BaseTokenHolder is IBaseTokenHolder {
    /// @notice Emitted when a withdrawal is initiated.
    event Withdrawal(address indexed from, address indexed l1Receiver, uint256 amount);

    /// @notice Emitted when a withdrawal with additional message is initiated.
    event WithdrawalWithMessage(address indexed from, address indexed l1Receiver, uint256 amount, bytes additionalData);

    /// @notice Modifier that restricts access to the InteropHandler only.
    modifier onlyInteropHandler() {
        if (msg.sender != address(L2_INTEROP_HANDLER)) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Gives out base tokens from the holder to a recipient.
    /// @dev This replaces the mint operation. Tokens are transferred from this contract's balance.
    /// @dev The actual transfer is done via L2BaseToken.transferFromTo to maintain balance consistency.
    /// @param _to The address to receive the base tokens.
    /// @param _amount The amount of base tokens to give out.
    function give(address _to, uint256 _amount) external override onlyInteropHandler {
        if (_amount == 0) {
            return;
        }

        // Transfer base tokens from this holder to the recipient
        // This uses the L2BaseToken's transferFromTo which handles balance updates
        L2_BASE_TOKEN_SYSTEM_CONTRACT.transferFromTo(address(this), _to, _amount);
    }

    /// @notice Initiates withdrawal of the base token to L1.
    /// @dev The sent msg.value is kept in this contract (increasing holder balance = decreasing circulating supply).
    /// @dev An L2->L1 message is sent via L1Messenger to allow claiming on L1.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable override {
        uint256 amount = msg.value;

        // Notify asset tracker about the withdrawal for chain balance tracking
        L2_ASSET_TRACKER.handleInitiateBaseTokenBridgingOnL2(amount);

        // Send the L2->L1 message for proof of withdrawal
        bytes memory message = _getL1WithdrawMessage(_l1Receiver, amount);
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Initiates withdrawal of the base token to L1 with additional data.
    /// @dev The sent msg.value is kept in this contract (increasing holder balance = decreasing circulating supply).
    /// @dev An L2->L1 message is sent via L1Messenger to allow claiming on L1.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable override {
        uint256 amount = msg.value;

        // Notify asset tracker about the withdrawal for chain balance tracking
        L2_ASSET_TRACKER.handleInitiateBaseTokenBridgingOnL2(amount);

        // Send the L2->L1 message for proof of withdrawal
        bytes memory message = _getExtendedWithdrawMessage(_l1Receiver, amount, msg.sender, _additionalData);
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);

        emit WithdrawalWithMessage(msg.sender, _l1Receiver, amount, _additionalData);
    }

    /// @dev Get the message to be sent to L1 to initiate a withdrawal.
    function _getL1WithdrawMessage(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodePacked(IMailboxImpl.finalizeEthWithdrawal.selector, _to, _amount);
    }

    /// @dev Get the extended message to be sent to L1 to initiate a withdrawal with additional data.
    function _getExtendedWithdrawMessage(
        address _to,
        uint256 _amount,
        address _sender,
        bytes memory _additionalData
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IMailboxImpl.finalizeEthWithdrawal.selector, _to, _amount, _sender, _additionalData);
    }

    /// @notice Fallback to accept base token transfers from InteropHandler only.
    /// @dev Restricts token reception to prevent accidental transfers.
    receive() external payable onlyInteropHandler {}
}

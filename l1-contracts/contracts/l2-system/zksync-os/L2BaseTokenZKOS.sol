// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2BaseTokenZKOS} from "./interfaces/IL2BaseTokenZKOS.sol";
import {IL2ToL1MessengerZKSyncOS} from "../../common/l2-helpers/IL2ToL1MessengerZKSyncOS.sol";
import {L2_ASSET_TRACKER, L2_BASE_TOKEN_HOLDER_ADDR, L2_COMPLEX_UPGRADER_ADDR, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR, MINT_BASE_TOKEN_HOOK} from "../../common/l2-helpers/L2ContractAddresses.sol";
import {INITIAL_BASE_TOKEN_HOLDER_BALANCE} from "../../common/Config.sol";
import {IMailboxImpl} from "../../state-transition/chain-interfaces/IMailboxImpl.sol";
import {BaseTokenHolderMintFailed, BaseTokenHolderTransferFailed, Unauthorized, WithdrawFailed} from "../../common/L1ContractErrors.sol";

/**
 * @title L2BaseTokenZKOS
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice L2 Base Token contract for ZK OS chains that only provides withdrawal functionality.
 * @dev Unlike the Era version, this contract does not manage token supply or balances.
 * @dev On ZK OS chains, the native ETH is used directly, so balance management is handled natively.
 * @dev This contract only provides the withdrawal interface to bridge ETH back to L1.
 *
 * ## Initialization (Genesis/Upgrade)
 *
 * During genesis or V31 upgrade, initializeBaseTokenHolderBalance() must be called to:
 * 1. Mint 2^127 - 1 tokens to this contract via the mint hook
 * 2. Transfer all tokens to BaseTokenHolder to establish the balance invariant
 */
contract L2BaseTokenZKOS is IL2BaseTokenZKOS {
    /// @notice The L1Messenger contract for sending messages to L1
    IL2ToL1MessengerZKSyncOS internal constant L1_MESSENGER =
        IL2ToL1MessengerZKSyncOS(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR);

    /// @notice Flag to track if initialization has been performed
    bool public initialized;

    /// @notice Initiate the withdrawal of the base token, funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable override {
        uint256 amount = _burnMsgValue();

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getL1WithdrawMessage(_l1Receiver, amount);
        // slither-disable-next-line unused-return
        L1_MESSENGER.sendToL1(message);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Initiate the withdrawal of the base token, with the sent message. The funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable override {
        uint256 amount = _burnMsgValue();

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getExtendedWithdrawMessage(_l1Receiver, amount, msg.sender, _additionalData);
        // slither-disable-next-line unused-return
        L1_MESSENGER.sendToL1(message);

        emit WithdrawalWithMessage(msg.sender, _l1Receiver, amount, _additionalData);
    }

    /*//////////////////////////////////////////////////////////////
                            INITIALIZATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Initializes the BaseTokenHolder's balance during genesis or V31 upgrade.
    /// @dev This function mints 2^127 - 1 tokens to this contract via the mint hook,
    /// @dev then transfers all tokens to BaseTokenHolder.
    /// @dev Can only be called by the ComplexUpgrader contract.
    /// @dev This function is idempotent - calling it when already initialized has no effect.
    function initializeBaseTokenHolderBalance() external {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }

        // Only initialize if not already done (idempotent)
        if (initialized) {
            return;
        }
        initialized = true;

        // Mint INITIAL_BASE_TOKEN_HOLDER_BALANCE tokens to this contract via the mint hook
        (bool mintSuccess, ) = MINT_BASE_TOKEN_HOOK.call(abi.encode(INITIAL_BASE_TOKEN_HOLDER_BALANCE));
        if (!mintSuccess) {
            revert BaseTokenHolderMintFailed();
        }

        // Transfer all minted tokens to BaseTokenHolder
        // slither-disable-next-line arbitrary-send-eth
        (bool transferSuccess, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: INITIAL_BASE_TOKEN_HOLDER_BALANCE}("");
        if (!transferSuccess) {
            revert BaseTokenHolderTransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                            INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @dev Burns the sent `msg.value` by sending it to BaseTokenHolder and notifying the AssetTracker.
    /// @return amount The amount of ETH that was burned.
    function _burnMsgValue() internal returns (uint256 amount) {
        amount = msg.value;

        // Notify L2AssetTracker of the outgoing bridging operation for balance tracking
        L2_ASSET_TRACKER.handleInitiateBaseTokenBridgingOnL2(amount);

        // Send the ETH to BaseTokenHolder (effectively "burning" from circulation)
        // slither-disable-next-line arbitrary-send-eth
        (bool success, ) = L2_BASE_TOKEN_HOLDER_ADDR.call{value: amount}("");
        if (!success) {
            revert WithdrawFailed();
        }
    }

    /// @dev Get the message to be sent to L1 to initiate a withdrawal.
    /// @param _to The L1 receiver address.
    /// @param _amount The amount being withdrawn.
    /// @return The encoded withdrawal message.
    function _getL1WithdrawMessage(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodePacked(IMailboxImpl.finalizeEthWithdrawal.selector, _to, _amount);
    }

    /// @dev Get the extended message to be sent to L1 to initiate a withdrawal with additional data.
    /// @param _to The L1 receiver address.
    /// @param _amount The amount being withdrawn.
    /// @param _sender The L2 sender address.
    /// @param _additionalData Additional data to include in the message.
    /// @return The encoded extended withdrawal message.
    function _getExtendedWithdrawMessage(
        address _to,
        uint256 _amount,
        address _sender,
        bytes memory _additionalData
    ) internal pure returns (bytes memory) {
        // solhint-disable-next-line func-named-parameters
        return abi.encodePacked(IMailboxImpl.finalizeEthWithdrawal.selector, _to, _amount, _sender, _additionalData);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2BaseTokenBase} from "./interfaces/IL2BaseTokenBase.sol";
import {IL2ToL1Messenger} from "../common/l2-helpers/IL2ToL1Messenger.sol";
import {IMailboxImpl} from "../state-transition/chain-interfaces/IMailboxImpl.sol";
import {L2_BASE_TOKEN_HOLDER, L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";

/**
 * @title L2BaseTokenBase
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Abstract base contract for L2 Base Token implementations.
 * @dev This contract contains the shared withdrawal logic for both Era and ZK OS versions.
 */
abstract contract L2BaseTokenBase is IL2BaseTokenBase {
    /// @notice The L1Messenger contract for sending messages to L1
    IL2ToL1Messenger internal constant L1_MESSENGER = IL2ToL1Messenger(L2_TO_L1_MESSENGER_SYSTEM_CONTRACT_ADDR);

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

    /// @dev Burns the sent `msg.value` by sending it to BaseTokenHolder and notifying the AssetTracker.
    /// @return amount The amount of ETH that was burned.
    function _burnMsgValue() internal virtual returns (uint256 amount) {
        amount = msg.value;

        // Transfer the ether to BaseTokenHolder and notify L2AssetTracker
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: amount}();
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

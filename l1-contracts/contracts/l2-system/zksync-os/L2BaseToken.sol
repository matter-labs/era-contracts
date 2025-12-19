// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_TO_L1_MESSENGER_SYSTEM_CONTRACT, L2_COMPLEX_UPGRADER_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {IMailboxImpl} from "contracts/state-transition/chain-interfaces/IMailbox.sol";
import {Burner} from "./Burner.sol";
import {IBaseToken} from "./ZKOSContractHelper.sol";
import {L1MessengerSendFailed} from "./errors/ZKOSContractErrors.sol";
import {InvalidCaller} from "contracts/common/L1ContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Native ETH contract.
 * @dev It does NOT provide interfaces for personal interaction with tokens like `transfer`, `approve`, and `transferFrom`.
 * Instead, this contract is used only as an entrypoint for native token withdrawals.
 */
contract L2BaseToken is IBaseToken {

    /// @dev Only allows calls from the complex upgrader contract on L2.
    modifier onlyUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert InvalidCaller(msg.sender);
        }
        _;
    }

    /// @notice Initializes the contract.
    /// @dev This function is used to initialize the contract with the initial values.
    function initL2() public onlyUpgrader {
        _initialize();
    }

    /// @dev Internal initialization function. Can be overridden by derived contracts.
    function _initialize() internal virtual {

    }

    /// @notice Initiate the withdrawal of the base token, funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable {
        uint256 amount = msg.value;

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getL1WithdrawMessage(_l1Receiver, amount);
        bytes32 msgHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);
        if (msgHash == bytes32(0)) revert L1MessengerSendFailed();

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Initiate the withdrawal of the base token, with the sent message. The funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable {
        uint256 amount = msg.value;

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getExtendedWithdrawMessage(_l1Receiver, amount, msg.sender, _additionalData);
        bytes32 msgHash = L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);
        if (msgHash == bytes32(0)) revert L1MessengerSendFailed();

        emit WithdrawalWithMessage(msg.sender, _l1Receiver, amount, _additionalData);
    }

    /// @dev Get the message to be sent to L1 to initiate a withdrawal.
    function _getL1WithdrawMessage(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodePacked(IMailboxImpl.finalizeEthWithdrawal.selector, _to, _amount);
    }

    /// @dev Get the message to be sent to L1 to initiate a withdrawal.
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

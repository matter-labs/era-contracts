// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL2BaseTokenBase} from "./interfaces/IL2BaseTokenBase.sol";
import {IMailboxLegacy} from "../state-transition/chain-interfaces/IMailboxLegacy.sol";
import {L2_COMPLEX_UPGRADER_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {
    L2_ASSET_TRACKER,
    L2_BASE_TOKEN_HOLDER,
    L2_TO_L1_MESSENGER_SYSTEM_CONTRACT
} from "../common/l2-helpers/L2ContractInterfaces.sol";
import {Unauthorized} from "../common/L1ContractErrors.sol";

/**
 * @title L2BaseTokenBase
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Abstract base contract for L2 Base Token implementations.
 * @dev This contract contains the shared withdrawal logic for both Era and ZK OS versions.
 * @dev Pre-V31 storage variables (eraAccountBalance, __DEPRECATED_totalSupply) are declared here because they existed before the V31 upgrade. The storage gap allows adding new shared variables in future upgrades.
 */
abstract contract L2BaseTokenBase is IL2BaseTokenBase {
    /// @notice Ensures that only the ComplexUpgrader can call the function.
    modifier onlyComplexUpgrader() {
        if (msg.sender != L2_COMPLEX_UPGRADER_ADDR) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice The balances of the users.
    /// @dev Only used by the Era implementation. Declared in the base contract because it existed prior to V31.
    mapping(address account => uint256 balance) internal eraAccountBalance;

    /// @notice Deprecated: The old storage variable for total supply.
    /// @dev Only read during the V31 upgrade to initialize the BaseTokenHolder balance correctly. After V31, totalSupply is computed dynamically from the BaseTokenHolder's balance.
    /// @dev Only used by the Era implementation. Declared in the base contract because it existed prior to V31.
    // slither-disable-next-line uninitialized-state
    uint256 internal __DEPRECATED_totalSupply;

    /// @notice Whether initializeBaseTokenHolderBalance has already been called.
    bool internal baseTokenHolderInitialized;

    /// @dev Storage gap to allow adding new shared storage variables in future upgrades.
    uint256[47] private __gap;

    /// @notice Initiate the withdrawal of the base token, funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable override {
        uint256 amount = _burnMsgValue(L2_ASSET_TRACKER.L1_CHAIN_ID());

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getL1WithdrawMessage(_l1Receiver, amount);
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Initiate the withdrawal of the base token, with the sent message. The funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable override {
        uint256 amount = _burnMsgValue(L2_ASSET_TRACKER.L1_CHAIN_ID());

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getExtendedWithdrawMessage(_l1Receiver, amount, msg.sender, _additionalData);
        // slither-disable-next-line unused-return
        L2_TO_L1_MESSENGER_SYSTEM_CONTRACT.sendToL1(message);

        emit WithdrawalWithMessage(msg.sender, _l1Receiver, amount, _additionalData);
    }

    /// @dev Burns the sent `msg.value` by sending it to BaseTokenHolder and notifying the AssetTracker.
    /// @param _toChainId The chain ID which the funds are sent to. L1 chain ID is not accessible within this
    /// contract, so we use 0 as a placeholder to keep the initialization of the contract simpler.
    /// @return amount The amount of ETH that was burned.
    function _burnMsgValue(uint256 _toChainId) internal virtual returns (uint256 amount) {
        amount = msg.value;

        // Transfer the ether to BaseTokenHolder and notify L2AssetTracker
        L2_BASE_TOKEN_HOLDER.burnAndStartBridging{value: amount}(_toChainId);
    }

    /// @dev Get the message to be sent to L1 to initiate a withdrawal.
    /// @param _to The L1 receiver address.
    /// @param _amount The amount being withdrawn.
    /// @return The encoded withdrawal message.
    function _getL1WithdrawMessage(address _to, uint256 _amount) internal pure returns (bytes memory) {
        return abi.encodePacked(IMailboxLegacy.finalizeEthWithdrawal.selector, _to, _amount);
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
        return abi.encodePacked(IMailboxLegacy.finalizeEthWithdrawal.selector, _to, _amount, _sender, _additionalData);
    }
}

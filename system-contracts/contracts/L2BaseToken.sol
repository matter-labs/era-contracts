// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IBaseToken} from "./interfaces/IBaseToken.sol";
import {SystemContractBase} from "./abstract/SystemContractBase.sol";
import {BASE_TOKEN_HOLDER_ADDRESS, BOOTLOADER_FORMAL_ADDRESS, COMPLEX_UPGRADER_CONTRACT, DEPLOYER_SYSTEM_CONTRACT, L1_MESSENGER_CONTRACT, L2_ASSET_TRACKER, L2_INTEROP_HANDLER, MSG_VALUE_SYSTEM_CONTRACT} from "./Constants.sol";
import {IMailboxImpl} from "./interfaces/IMailboxImpl.sol";
import {InsufficientFunds, Unauthorized} from "./SystemContractErrors.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Native ETH contract.
 * @dev It does NOT provide interfaces for personal interaction with tokens like `transfer`, `approve`, and `transferFrom`.
 * Instead, this contract is used by the bootloader and `MsgValueSimulator`/`ContractDeployer` system contracts
 * to perform the balance changes while simulating the `msg.value` Ethereum behavior.
 */
contract L2BaseToken is IBaseToken, SystemContractBase {
    /// @notice The initial balance of the BaseTokenHolder contract (2^127 - 1).
    /// @dev Used to derive the real circulating supply: INITIAL - currentHolderBalance = circulatingSupply
    uint256 public constant INITIAL_BASE_TOKEN_HOLDER_BALANCE = (2 ** 127) - 1;

    /// @notice The balances of the users.
    mapping(address account => uint256 balance) internal balance;

    /// @notice Returns the total circulating supply of base tokens.
    /// @dev Computed as: INITIAL_BASE_TOKEN_HOLDER_BALANCE - current holder balance
    /// @dev This replaces the previous storage-based totalSupply that was incremented on mint.
    function totalSupply() external view override returns (uint256) {
        return INITIAL_BASE_TOKEN_HOLDER_BALANCE - balance[BASE_TOKEN_HOLDER_ADDRESS];
    }

    /// @notice Transfer tokens from one address to another.
    /// @param _from The address to transfer the ETH from.
    /// @param _to The address to transfer the ETH to.
    /// @param _amount The amount of ETH in wei being transferred.
    /// @dev This function can be called only by trusted system contracts.
    /// @dev This function also emits "Transfer" event, which might be removed
    /// later on.
    function transferFromTo(address _from, address _to, uint256 _amount) external override {
        if (
            msg.sender != MSG_VALUE_SYSTEM_CONTRACT &&
            msg.sender != address(DEPLOYER_SYSTEM_CONTRACT) &&
            msg.sender != BOOTLOADER_FORMAL_ADDRESS &&
            msg.sender != address(L2_INTEROP_HANDLER)
        ) {
            revert Unauthorized(msg.sender);
        }

        uint256 fromBalance = balance[_from];
        if (fromBalance < _amount) {
            revert InsufficientFunds(_amount, fromBalance);
        }
        unchecked {
            balance[_from] = fromBalance - _amount;
            // Overflow not possible: the sum of all balances is capped by totalSupply, and the sum is preserved by
            // decrementing then incrementing.
            balance[_to] += _amount;
        }

        emit Transfer(_from, _to, _amount);
    }

    /// @notice Returns ETH balance of an account
    /// @dev It takes `uint256` as an argument to be able to properly simulate the behaviour of the
    /// Ethereum's `BALANCE` opcode that accepts uint256 as an argument and truncates any upper bits
    /// @param _account The address of the account to return the balance of.
    function balanceOf(uint256 _account) external view override returns (uint256) {
        return balance[address(uint160(_account))];
    }

    /// @notice Increase the balance of the receiver by transferring from BaseTokenHolder.
    /// @dev This method is only callable by the bootloader.
    /// @dev The totalSupply is now computed from BaseTokenHolder balance, so we only update balances.
    /// @param _account The address which to mint the funds to.
    /// @param _amount The amount of ETH in wei to be minted.
    function mint(address _account, uint256 _amount) external override onlyCallFromBootloaderOrInteropHandler {
        L2_ASSET_TRACKER.handleFinalizeBaseTokenBridgingOnL2(_amount);
        // Transfer from BaseTokenHolder to the recipient
        // This decreases holder balance, which increases totalSupply() automatically
        balance[BASE_TOKEN_HOLDER_ADDRESS] -= _amount;
        balance[_account] += _amount;
        emit Mint(_account, _amount);
    }

    /// @notice Initiate the withdrawal of the base token, funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    function withdraw(address _l1Receiver) external payable override {
        uint256 amount = _burnMsgValue();

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getL1WithdrawMessage(_l1Receiver, amount);
        L1_MESSENGER_CONTRACT.sendToL1(message);

        emit Withdrawal(msg.sender, _l1Receiver, amount);
    }

    /// @notice Initiate the withdrawal of the base token, with the sent message. The funds will be available to claim on L1 `finalizeEthWithdrawal` method.
    /// @param _l1Receiver The address on L1 to receive the funds.
    /// @param _additionalData Additional data to be sent to L1 with the withdrawal.
    function withdrawWithMessage(address _l1Receiver, bytes calldata _additionalData) external payable override {
        uint256 amount = _burnMsgValue();

        // Send the L2 log, a user could use it as proof of the withdrawal
        bytes memory message = _getExtendedWithdrawMessage(_l1Receiver, amount, msg.sender, _additionalData);
        L1_MESSENGER_CONTRACT.sendToL1(message);

        emit WithdrawalWithMessage(msg.sender, _l1Receiver, amount, _additionalData);
    }

    /// @dev The function burn the sent `msg.value`.
    /// NOTE: Since this contract holds the mapping of all ether balances of the system,
    /// the sent `msg.value` is added to the `this` balance before the call.
    /// So the balance of `address(this)` is always bigger or equal to the `msg.value`!
    function _burnMsgValue() internal returns (uint256 amount) {
        amount = msg.value;
        /// @dev This function is called to check if the token is withdrawable.
        L2_ASSET_TRACKER.handleInitiateBaseTokenBridgingOnL2(amount);

        // Transfer the ether back to BaseTokenHolder (effectively "burning" from circulation)
        unchecked {
            // This is safe, since this contract holds the ether balances, and if user
            // sends a `msg.value` it will be added to the contract (`this`) balance.
            balance[address(this)] -= amount;
            // Return to BaseTokenHolder, which decreases totalSupply() automatically
            balance[BASE_TOKEN_HOLDER_ADDRESS] += amount;
        }
    }

    function burnMsgValue() external payable override onlyCallFromInteropCenterOrNTV {
        _burnMsgValue();
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

    /// @notice Initializes the BaseTokenHolder's balance during the V31 upgrade.
    /// @dev This function sets the initial balance of BASE_TOKEN_HOLDER to INITIAL_BASE_TOKEN_HOLDER_BALANCE (2^127 - 1).
    /// @dev Can only be called by the ComplexUpgrader contract.
    /// @dev This function is idempotent - calling it when the balance is already set has no effect.
    function initializeBaseTokenHolderBalance() external {
        if (msg.sender != address(COMPLEX_UPGRADER_CONTRACT)) {
            revert Unauthorized(msg.sender);
        }

        // Only initialize if not already set (idempotent)
        if (balance[BASE_TOKEN_HOLDER_ADDRESS] == 0) {
            balance[BASE_TOKEN_HOLDER_ADDRESS] = INITIAL_BASE_TOKEN_HOLDER_BALANCE;
        }
    }
}

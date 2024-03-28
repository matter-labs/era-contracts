// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {IPaymaster, ExecutionResult, PAYMASTER_VALIDATION_SUCCESS_MAGIC} from "./interfaces/IPaymaster.sol";
import {IPaymasterFlow} from "./interfaces/IPaymasterFlow.sol";
import {Transaction, BOOTLOADER_ADDRESS} from "./L2ContractHelper.sol";

// This is a dummy paymaster. It expects the paymasterInput to contain its "signature" as well as the needed exchange rate.
// It supports only approval-based paymaster flow.
contract TestnetPaymaster is IPaymaster {
    function validateAndPayForPaymasterTransaction(
        bytes32,
        bytes32,
        Transaction calldata _transaction
    ) external payable returns (bytes4 magic, bytes memory context) {
        // By default we consider the transaction as accepted.
        magic = PAYMASTER_VALIDATION_SUCCESS_MAGIC;

        require(msg.sender == BOOTLOADER_ADDRESS, "Only bootloader can call this contract");
        require(_transaction.paymasterInput.length >= 4, "The standard paymaster input must be at least 4 bytes long");

        bytes4 paymasterInputSelector = bytes4(_transaction.paymasterInput[0:4]);
        if (paymasterInputSelector == IPaymasterFlow.approvalBased.selector) {
            // While the actual data consists of address, uint256 and bytes data,
            // the data is not needed for the testnet paymaster
            (address token, uint256 amount, ) = abi.decode(_transaction.paymasterInput[4:], (address, uint256, bytes));

            // Firstly, we verify that the user has provided enough allowance
            address userAddress = address(uint160(_transaction.from));
            address thisAddress = address(this);

            uint256 providedAllowance = IERC20(token).allowance(userAddress, thisAddress);
            require(providedAllowance >= amount, "The user did not provide enough allowance");

            // The testnet paymaster exchanges X wei of the token to the X wei of ETH.
            uint256 requiredETH = _transaction.gasLimit * _transaction.maxFeePerGas;
            if (amount < requiredETH) {
                // Important note: while this clause definitely means that the user
                // has underpaid the paymaster and the transaction should not accepted,
                // we do not want the transaction to revert, because for fee estimation
                // we allow users to provide smaller amount of funds then necessary to preserve
                // the property that if using X gas the transaction success, then it will succeed with X+1 gas.
                magic = bytes4(0);
            }

            // Pulling all the tokens from the user
            try IERC20(token).transferFrom(userAddress, thisAddress, amount) {} catch (bytes memory revertReason) {
                // If the revert reason is empty or represented by just a function selector,
                // we replace the error with a more user-friendly message
                if (revertReason.length <= 4) {
                    revert("Failed to transferFrom from users' account");
                } else {
                    assembly {
                        revert(add(0x20, revertReason), mload(revertReason))
                    }
                }
            }

            // The bootloader never returns any data, so it can safely be ignored here.
            (bool success, ) = payable(BOOTLOADER_ADDRESS).call{value: requiredETH}("");
            require(success, "Failed to transfer funds to the bootloader");
        } else {
            revert("Unsupported paymaster flow");
        }
    }

    function postTransaction(
        bytes calldata _context,
        Transaction calldata _transaction,
        bytes32,
        bytes32,
        ExecutionResult _txResult,
        uint256 _maxRefundedGas
    ) external payable override {
        // Refunds are not supported yet.
    }

    receive() external payable {}
}

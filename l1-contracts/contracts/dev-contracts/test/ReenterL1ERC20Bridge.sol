// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {IL1ERC20Bridge} from "../../bridge/interfaces/IL1ERC20Bridge.sol";

contract ReenterL1ERC20Bridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    IL1ERC20Bridge l1Erc20Bridge;

    enum FunctionToCall {
        Unset,
        LegacyDeposit,
        Deposit,
        ClaimFailedDeposit,
        FinalizeWithdrawal
    }

    FunctionToCall functionToCall;

    function setBridge(IL1ERC20Bridge _l1Erc20Bridge) external {
        l1Erc20Bridge = _l1Erc20Bridge;
    }

    function setFunctionToCall(FunctionToCall _functionToCall) external {
        functionToCall = _functionToCall;
    }

    fallback() external payable {
        if (functionToCall == FunctionToCall.LegacyDeposit) {
            l1Erc20Bridge.deposit({
                _l2Receiver: address(0),
                _l1Token: address(0),
                _amount: 0,
                _l2TxGasLimit: 0,
                _l2TxGasPerPubdataByte: 0,
                _refundRecipient: address(0)
            });
        } else if (functionToCall == FunctionToCall.Deposit) {
            l1Erc20Bridge.deposit({
                _l2Receiver: address(0),
                _l1Token: address(0),
                _amount: 0,
                _l2TxGasLimit: 0,
                _l2TxGasPerPubdataByte: 0,
                _refundRecipient: address(0)
            });
        } else if (functionToCall == FunctionToCall.ClaimFailedDeposit) {
            bytes32[] memory merkleProof;
            l1Erc20Bridge.claimFailedDeposit({
                _depositSender: address(0),
                _l1Token: address(0),
                _l2TxHash: bytes32(0),
                _l2BatchNumber: 0,
                _l2MessageIndex: 0,
                _l2TxNumberInBatch: 0,
                _merkleProof: merkleProof
            });
        } else if (functionToCall == FunctionToCall.FinalizeWithdrawal) {
            bytes32[] memory merkleProof;
            l1Erc20Bridge.finalizeWithdrawal({
                _l2BatchNumber: 0,
                _l2MessageIndex: 0,
                _l2TxNumberInBatch: 0,
                _message: bytes(""),
                _merkleProof: merkleProof
            });
        } else {
            revert("Unset function to call");
        }
    }

    receive() external payable {
        // revert("Receive not allowed");
    }
}

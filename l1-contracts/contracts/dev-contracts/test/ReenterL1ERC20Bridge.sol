// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IL1ERC20Bridge} from "../../bridge/interfaces/IL1ERC20Bridge.sol";

contract ReenterL1ERC20Bridge {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    IL1ERC20Bridge l1Erc20Bridge;

    enum FunctionToCall {
        Unset,
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
        if (functionToCall == FunctionToCall.FinalizeWithdrawal) {
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

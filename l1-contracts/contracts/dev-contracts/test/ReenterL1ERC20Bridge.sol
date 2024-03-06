// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

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
            l1Erc20Bridge.deposit(address(0), address(0), 0, 0, 0);
        } else if (functionToCall == FunctionToCall.Deposit) {
            l1Erc20Bridge.deposit(address(0), address(0), 0, 0, 0, address(0));
        } else if (functionToCall == FunctionToCall.ClaimFailedDeposit) {
            bytes32[] memory merkleProof;
            l1Erc20Bridge.claimFailedDeposit(address(0), address(0), bytes32(0), 0, 0, 0, merkleProof);
        } else if (functionToCall == FunctionToCall.FinalizeWithdrawal) {
            bytes32[] memory merkleProof;
            l1Erc20Bridge.finalizeWithdrawal(0, 0, 0, bytes(""), merkleProof);
        } else {
            revert("Unset function to call");
        }
    }

    receive() external payable {
        // revert("Receive not allowed");
    }
}

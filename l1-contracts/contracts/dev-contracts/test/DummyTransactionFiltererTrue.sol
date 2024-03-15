// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {ITransactionFilterer} from "solpp/state-transition/chain-interfaces/ITransactionFilterer.sol";
import {BridgehubL2TransactionRequest} from "solpp/common/Messaging.sol";

contract TransactionFiltererTrue is ITransactionFilterer {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function isTransactionAllowed(BridgehubL2TransactionRequest memory _request) external view returns (bool) {
        return true;
    }
}

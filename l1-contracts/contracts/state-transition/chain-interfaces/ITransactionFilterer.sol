// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {BridgehubL2TransactionRequest} from "../../common/Messaging.sol";

/// @title The interface of the L1 <-> L2 transaction filterer.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ITransactionFilterer {
    function isTransactionAllowed(BridgehubL2TransactionRequest memory _request) external view returns (bool);
}

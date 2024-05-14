// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {CommitBatchInfo} from "../../../l1-contracts/contracts/state-transition/chain-interfaces/IExecutor.sol";

interface IBatchAggregator{
    bytes32 batchStorage;
    function commitBatch(CommitBatchInfo batch) external;
    function returnBatchesAndClearState() external;
}
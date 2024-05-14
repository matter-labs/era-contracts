// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IBatchAggregator} from "./interfaces/IBatchAggregator.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";
import {CommitBatchInfo} from "../../l1-contracts/contracts/state-transition/chain-interfaces/IExecutor.sol";

contract BatchAggregator is IBatchAggregator, ISystemContract {
    CommitBatchInfo[] batchStorage;
    function commitBatch(CommitBatchInfo batch) external{
        batchStorage.push(batch);
    }
    function returnBatchesAndClearState() external returns(bytes32 batchInfo) {
        batchInfo = abi.encode(batchStorage);
        batchStorage = [];
    }
}
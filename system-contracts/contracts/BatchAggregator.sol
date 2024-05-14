// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {IBatchAggregator} from "./interfaces/IBatchAggregator.sol";
import {ISystemContract} from "./interfaces/ISystemContract.sol";

contract BatchAggregator is IBatchAggregator, ISystemContract {
    bytes[] batchStorage;
    function commitBatch(bytes memory batch) external{
        batchStorage.push(batch);
    }
    function returnBatchesAndClearState() external returns(bytes memory batchInfo) {
        batchInfo = abi.encode(batchStorage);
        delete batchStorage;
    }
}
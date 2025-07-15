// SPDX-License-Identifier: MIT

import {ExecutorFacet} from "../../state-transition/chain-deps/facets/Executor.sol";
import {PriorityOperation, PriorityQueue} from "../../state-transition/libraries/PriorityQueue.sol";

pragma solidity 0.8.28;

contract TestExecutor is ExecutorFacet {
    constructor() ExecutorFacet(block.chainid) {}

    using PriorityQueue for PriorityQueue.Queue;

    function setPriorityTreeStartIndex(uint256 _startIndex) external {
        s.priorityTree.startIndex = _startIndex;
    }

    function appendPriorityOp(bytes32 _hash) external {
        s.__DEPRECATED_priorityQueue.pushBack(
            PriorityOperation({canonicalTxHash: _hash, expirationTimestamp: type(uint64).max, layer2Tip: 0})
        );
    }

    function setPriorityTreeHistoricalRoot(bytes32 _root) external {
        s.priorityTree.historicalRoots[_root] = true;
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

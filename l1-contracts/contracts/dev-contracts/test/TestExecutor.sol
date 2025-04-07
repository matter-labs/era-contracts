// SPDX-License-Identifier: MIT

import {ExecutorFacet} from "../../state-transition/chain-deps/facets/Executor.sol";
import {PriorityQueue, PriorityOperation} from "../../state-transition/libraries/PriorityQueue.sol";

pragma solidity 0.8.24;

contract TestExecutor is ExecutorFacet {
    constructor() ExecutorFacet(block.chainid) {}

    using PriorityQueue for PriorityQueue.Queue;

    function setPriorityTreeStartIndex(uint256 _startIndex) external {
        s.priorityTree.startIndex = _startIndex;
    }

    // /// @dev Since we want to test the blob functionality we want mock the calls to the blobhash opcode.
    // function _getBlobVersionedHash(uint256 _index) internal view virtual override returns (bytes32 versionedHash) {
    //     (bool success, bytes memory data) = s.blobVersionedHashRetriever.staticcall(abi.encode(_index));
    //     require(success, "vc");
    //     versionedHash = abi.decode(data, (bytes32));
    // }

    function appendPriorityOp(bytes32 _hash) external {
        s.priorityQueue.pushBack(
            PriorityOperation({canonicalTxHash: _hash, expirationTimestamp: type(uint64).max, layer2Tip: 0})
        );
    }

    // add this to be excluded from coverage report
    function test() internal virtual {}
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {ZKChainBase} from "../../state-transition/chain-deps/facets/ZKChainBase.sol";

contract MockExecutorFacet is ZKChainBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function saveL2LogsRootHash(uint256 _batchNumber, bytes32 _l2LogsTreeRoot) external {
        s.totalBatchesExecuted = _batchNumber;
        s.l2LogsRootHashes[_batchNumber] = _l2LogsTreeRoot;
    }

    function setExecutedBatches(uint256 _batchNumber) external {
        s.totalBatchesExecuted = _batchNumber;
        s.totalBatchesCommitted = _batchNumber;
        s.totalBatchesVerified = _batchNumber;
    }
}

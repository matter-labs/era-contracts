// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../zksync/facets/Base.sol";

contract MockExecutorFacet is Base {
    function saveL2LogsRootHash(uint256 _batchNumber, bytes32 _l2LogsTreeRoot) external {
        s.totalBatchesExecuted = _batchNumber;
        s.l2LogsRootHashes[_batchNumber] = _l2LogsTreeRoot;
    }
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import "../../state-transition/chain-deps/facets/ZkSyncStateTransitionBase.sol";

contract MockExecutorFacet is ZkSyncStateTransitionBase {
    // add this to be excluded from coverage report
    function test() internal virtual {}

    function saveL2LogsRootHash(uint256 _batchNumber, bytes32 _l2LogsTreeRoot) external {
        s.totalBatchesExecuted = _batchNumber;
        s.l2LogsRootHashes[_batchNumber] = _l2LogsTreeRoot;
    }
}

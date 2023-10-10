// SPDX-License-Identifier: MIT

pragma solidity ^0.8.13;

import "../../proof-system/chain-deps/facets/Base.sol";

contract MockExecutorFacet is ProofChainBase {
    function saveL2LogsRootHash(uint256 _batchNumber, bytes32 _l2LogsTreeRoot) external {
        chainStorage.totalBatchesExecuted = _batchNumber;
        chainStorage.l2LogsRootHashes[_batchNumber] = _l2LogsTreeRoot;
    }
}

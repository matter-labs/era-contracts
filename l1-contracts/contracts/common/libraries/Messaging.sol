// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

bytes32 constant BATCH_LEAF_PADDING = keccak256("zkSync:BatchLeaf");
bytes32 constant CHAIN_ID_LEAF_PADDING = keccak256("zkSync:ChainIdLeaf");

library Messaging {
    function batchLeafHash(bytes32 batchRoot, uint256 batchNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(BATCH_LEAF_PADDING, batchRoot, batchNumber));
    }

    function chainIdLeafHash(bytes32 chainIdRoot, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(CHAIN_ID_LEAF_PADDING, chainIdRoot, chainId));
    }
}

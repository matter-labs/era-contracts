// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

library Messaging {
    bytes32 constant BATCH_LEAF_PADDING = keccak256("zkSync:BatchLeaf");
    function batchLeafHash(bytes32 batchRoot, uint256 batchNumber) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(BATCH_LEAF_PADDING, batchRoot, batchNumber));
    }

    // FIXME: it has to be different from the BATCH_LEAF_PADDING
    bytes32 constant CHAIN_ID_LEAF_PADDING = keccak256("zkSync:ChainIdLeaf");
    function chainIdLeafHash(bytes32 chainIdRoot, uint256 chainId) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(CHAIN_ID_LEAF_PADDING, chainIdRoot, chainId));
    }
}

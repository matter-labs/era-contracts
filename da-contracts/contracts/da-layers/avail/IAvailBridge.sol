// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IVectorx} from "./IVectorx.sol";

interface IAvailBridge {
    // solhint-disable-next-line gas-struct-packing
    struct Message {
        // single-byte prefix representing the message type
        bytes1 messageType;
        // address of message sender
        bytes32 from;
        // address of message receiver
        bytes32 to;
        // origin chain code
        uint32 originDomain;
        // destination chain code
        uint32 destinationDomain;
        // data being sent
        bytes data;
        // nonce
        uint64 messageId;
    }

    struct MerkleProofInput {
        // proof of inclusion for the data root
        bytes32[] dataRootProof;
        // proof of inclusion of leaf within blob/bridge root
        bytes32[] leafProof;
        // abi.encodePacked(startBlock, endBlock) of header range commitment on vectorx
        bytes32 rangeHash;
        // index of the data root in the commitment tree
        uint256 dataRootIndex;
        // blob root to check proof against, or reconstruct the data root
        bytes32 blobRoot;
        // bridge root to check proof against, or reconstruct the data root
        bytes32 bridgeRoot;
        // leaf being proven
        bytes32 leaf;
        // index of the leaf in the blob/bridge root tree
        uint256 leafIndex;
    }

    function vectorx() external view returns (IVectorx vectorx);

    function verifyBlobLeaf(MerkleProofInput calldata input) external view returns (bool);
}

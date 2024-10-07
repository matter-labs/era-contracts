// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.24;

import {IVectorx} from "./IVectorx.sol";

interface IAvailBridge {
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

    event MessageReceived(bytes32 indexed from, address indexed to, uint256 messageId);
    event MessageSent(address indexed from, bytes32 indexed to, uint256 messageId);

    error AlreadyBridged();
    error ArrayLengthMismatch();
    error BlobRootEmpty();
    error BridgeRootEmpty();
    error DataRootCommitmentEmpty();
    error FeeTooLow();
    error InvalidAssetId();
    error InvalidDataLength();
    error InvalidDataRootProof();
    error InvalidDomain();
    error InvalidDestinationOrAmount();
    error InvalidFungibleTokenTransfer();
    error InvalidLeaf();
    error InvalidMerkleProof();
    error InvalidMessage();
    error UnlockFailed();
    error WithdrawFailed();

    function setPaused(bool status) external;
    function updateVectorx(address newVectorx) external;
    function updateTokens(bytes32[] calldata assetIds, address[] calldata tokenAddresses) external;
    function updateFeePerByte(uint256 newFeePerByte) external;
    function updateFeeRecipient(address newFeeRecipient) external;
    function withdrawFees() external;
    function receiveMessage(Message calldata message, MerkleProofInput calldata input) external;
    function receiveAVAIL(Message calldata message, MerkleProofInput calldata input) external;
    function receiveETH(Message calldata message, MerkleProofInput calldata input) external;
    function receiveERC20(Message calldata message, MerkleProofInput calldata input) external;
    function sendMessage(bytes32 recipient, bytes calldata data) external payable;
    function sendAVAIL(bytes32 recipient, uint256 amount) external;
    function sendETH(bytes32 recipient) external payable;
    function sendERC20(bytes32 assetId, bytes32 recipient, uint256 amount) external;
    function vectorx() external view returns (IVectorx vectorx);
    function verifyBlobLeaf(MerkleProofInput calldata input) external view returns (bool);
    function verifyBridgeLeaf(MerkleProofInput calldata input) external view returns (bool);
}

// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Unauthorized} from "./SystemContractErrors.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice MessageRootStorage contract for imported L2 message roots..
 * @dev
 */
contract L2MessageRootStorage {
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 msgRoot)) public msgRoots;
    mapping(bytes32 msgRoot => uint256 batchNumber) public batchNumberFromMsgRoot;
    mapping(bytes32 msgRoot => uint256 chainId) public chainIdFromMsgRoot;

    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32[] msgRootSides)) public msgRootSides;
    // mapping(bytes32 msgRoot => uint256 batchNumber) public batchNumberFromMsgRoot;

    function addMessageRoot(
        uint256 chainId,
        uint256 batchNumber,
        bytes32 msgRoot
    ) external {
        // todo add access control, onlyBootloader
        msgRoots[chainId][batchNumber] = msgRoot;
        // make sure we cannot have duplicates here.
        batchNumberFromMsgRoot[msgRoot] = batchNumber;
        chainIdFromMsgRoot[msgRoot] = chainId;
    }
}

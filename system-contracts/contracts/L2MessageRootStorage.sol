// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

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
    uint256 public pendingMessageRootIdsLength;
    struct PendingMessageRootId {
        uint256 chainId;
        uint256 batchNumber;
    }
    mapping(uint256 index => PendingMessageRootId) public pendingMessageRootIds;
    // mapping(bytes32 msgRoot => uint256 batchNumber) public batchNumberFromMsgRoot;

    event MessageRootAdded(uint256 indexed chainId, uint256 indexed batchNumber, bytes32[] sides);

    function addMessageRoot(uint256 chainId, uint256 batchNumber, bytes32[] memory sides) external {
        emit MessageRootAdded(chainId, batchNumber, sides);
        // kl todo add access control, onlyBootloader
        if (sides.length == 1) {
            // kl todo make sure we cannot have duplicates here.
            msgRoots[chainId][batchNumber] = sides[0];
            batchNumberFromMsgRoot[sides[0]] = batchNumber;
            chainIdFromMsgRoot[sides[0]] = chainId;
        } else {
            // msgRootSides[chainId][batchNumber] = sides;
            // pendingMessageRootIds[pendingMessageRootIdsLength] = PendingMessageRootId({
            //     chainId: chainId,
            //     batchNumber: batchNumber
            // });
            // pendingMessageRootIdsLength++;
            // kl todo add linking here
        }
    }

    function clearPendingMessageRootIds() external {
        return;
        // for
    }
}

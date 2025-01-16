// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {Unauthorized} from "./SystemContractErrors.sol";
import {BOOTLOADER_FORMAL_ADDRESS} from "./Constants.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Nullifer contract for L2->L2 txs.
 * @dev
 */
contract L2MessageRootStorage {
    mapping(uint256 chainId => mapping(uint256 blockNumber => bytes32 msgRoot)) public msgRoots;
    mapping(bytes32 msgRoot => uint256 blockNumber) public blockNumberFromMsgRoot;
    mapping(bytes32 msgRoot => uint256 chainId) public chainIdFromMsgRoot;

    function addMessageRoot(uint256 chainId, uint256 blockNumber, bytes32 msgRoot) external {
        // todo add access control, onlyBootloader
        msgRoots[chainId][blockNumber] = msgRoot;
        // make sure we cannot have duplicates here.
        blockNumberFromMsgRoot[msgRoot] = blockNumber;
        chainIdFromMsgRoot[msgRoot] = chainId;
    }
}

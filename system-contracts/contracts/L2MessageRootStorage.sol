// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {SystemContractBase} from "./abstract/SystemContractBase.sol";

event MessageRootAdded(uint256 indexed chainId, uint256 indexed blockNumber, bytes32[] sides);
error SidesLengthNotOne();
error MessageRootAlreadyExists();

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice MessageRootStorage contract responsible for storing the message roots of other chains on the L2.
 * @dev
 */
contract L2MessageRootStorage is SystemContractBase {
    mapping(uint256 chainId => mapping(uint256 blockOrBatchNumber => bytes32 msgRoot)) public msgRoots;

    function addMessageRoot(
        uint256 chainId,
        uint256 blockOrBatchNumber,
        bytes32[] calldata sides
    ) external onlyCallFromBootloader {
        if (sides.length != 1) {
            revert SidesLengthNotOne();
        }
        if (msgRoots[chainId][blockOrBatchNumber] != bytes32(0)) {
            revert MessageRootAlreadyExists();
        }
        msgRoots[chainId][blockOrBatchNumber] = sides[0];

        emit MessageRootAdded(chainId, blockOrBatchNumber, sides);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {SystemContractBase} from "./abstract/SystemContractBase.sol";

event MessageRootAdded(uint256 indexed chainId, uint256 indexed batchNumber, bytes32[] sides);
error SidesLengthNotOne();
error MessageRootAlreadyExists();

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice MessageRootStorage contract for imported L2 message roots..
 * @dev
 */
contract L2MessageRootStorage is SystemContractBase {
    mapping(uint256 chainId => mapping(uint256 batchNumber => bytes32 msgRoot)) public msgRoots;

    function addMessageRoot(
        uint256 chainId,
        uint256 batchNumber,
        bytes32[] memory sides
    ) external onlyCallFromBootloader {
        if (sides.length != 1) {
            revert SidesLengthNotOne();
        }
        if (msgRoots[chainId][batchNumber] != bytes32(0)) {
            revert MessageRootAlreadyExists();
        }
        msgRoots[chainId][batchNumber] = sides[0];

        emit MessageRootAdded(chainId, batchNumber, sides);
    }
}

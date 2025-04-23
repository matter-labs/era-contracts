// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {SystemContractBase} from "./abstract/SystemContractBase.sol";

event InteropRootAdded(uint256 indexed chainId, uint256 indexed blockNumber, bytes32[] sides);
error SidesLengthNotOne();
error InteropRootAlreadyExists();

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice InteropRootStorage contract responsible for storing the message roots of other chains on the L2.
 */
contract L2MessageRootStorage is SystemContractBase {
    /// @notice Mapping of chain ID to block or batch number to message root.
    mapping(uint256 chainId => mapping(uint256 blockOrBatchNumber => bytes32 msgRoot)) public msgRoots;

    /// @dev Adds a message root to the L2InteropRootStorage contract.
    /// @param chainId The chain ID of the chain that the message root is for.
    /// @param blockOrBatchNumber The block or batch number of the message root.
    /// For proof based interop it is block number. For commit based interop it is batch number.
    /// @param sides The message root sides.
    function addInteropRoot(
        uint256 chainId,
        uint256 blockOrBatchNumber,
        bytes32[] calldata sides
    ) external onlyCallFromBootloader {
        if (sides.length != 1) {
            /// This will only be supported for precommit based interop.
            revert SidesLengthNotOne();
        }
        if (msgRoots[chainId][blockOrBatchNumber] != bytes32(0)) {
            revert InteropRootAlreadyExists();
        }
        msgRoots[chainId][blockOrBatchNumber] = sides[0];

        emit InteropRootAdded(chainId, blockOrBatchNumber, sides);
    }
}

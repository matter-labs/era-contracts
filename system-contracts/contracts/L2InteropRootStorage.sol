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
contract L2InteropRootStorage is SystemContractBase {
    /// @notice Mapping of chain ID to block or batch number to message root.
    mapping(uint256 chainId => mapping(uint256 batchOrBlockNumber => bytes32 msgRoot)) public msgRoots;

    /// @dev Adds a message root to the L2InteropRootStorage contract.
    /// @dev For both proof-based and commit-based interop, the `sides` parameter contains only the root.
    /// @dev Once pre-commit interop is introduced, `sides` will include both the root and its associated sides.
    /// @dev This interface is preserved now so that enabling pre-commit interop later requires no changes in interface.
    /// @dev In proof-based and pre-commit interop, `batchOrBlockNumber` represents the block number, in commit-based interop,
    /// it represents the batch number. This distinction reflects the implementation requirements  of each interop finality form.
    /// @param chainId The chain ID of the chain that the message root is for.
    /// @param batchOrBlockNumber The block or batch number of the message root. Either of block number or batch number will be used,
    // depends on finality form of interop, mentioned above.
    /// @param sides The message root sides.
    function addInteropRoot(
        uint256 chainId,
        uint256 batchOrBlockNumber,
        bytes32[] calldata sides
    ) external onlyCallFromBootloader {
        // In the current code sides should only contain the Interop Root itself, as mentioned above.
        if (sides.length != 1) {
            revert SidesLengthNotOne();
        }

        // Make sure that msgRoots for specified chainId and batchOrBlockNumber wasn't set already.
        if (msgRoots[chainId][batchOrBlockNumber] != bytes32(0)) {
            revert InteropRootAlreadyExists();
        }

        // Set msgRoots for specified chainId and batchOrBlockNumber, emit event.
        msgRoots[chainId][batchOrBlockNumber] = sides[0];

        emit InteropRootAdded(chainId, batchOrBlockNumber, sides);
    }
}

// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {SystemContractBase} from "./SystemContractBase.sol";

event InteropRootAdded(uint256 indexed chainId, uint256 indexed blockNumber, bytes32[] sides);
error SidesLengthNotOne();
error InteropRootAlreadyExists();
error MessageRootIsZero();

/// @dev For both proof-based and commit-based interop, the `sides` parameter contains only the root.
/// @dev Once pre-commit interop is introduced, `sides` will include both the root and its associated sides.
/// @dev This interface is preserved now so that enabling pre-commit interop later requires no changes in interface.
/// @dev In proof-based and pre-commit interop, `blockOrBatchNumber` represents the block number, in commit-based interop,
/// it represents the batch number. This distinction reflects the implementation requirements  of each interop finality form.
/// @param chainId The chain ID of the chain that the message root is for.
/// @param blockOrBatchNumber The block or batch number of the message root. Either of block number or batch number will be used,
/// depends on finality form of interop.
/// @param sides The message root sides. Note, that `sides` here are coming from `DynamicIncrementalMerkle` nomenclature.
struct InteropRoot {
    uint256 chainId;
    uint256 blockOrBatchNumber;
    bytes32[] sides;
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice An abstract contract responsible for the common logic related to
   storing the message roots of other chains on the L2.
 */
abstract contract L2InteropRootStorageBase is SystemContractBase {
    /// @notice Mapping of chain ID to block or batch number to message root.
    mapping(uint256 chainId => mapping(uint256 blockOrBatchNumber => bytes32 interopRoot)) public interopRoots;

    function _addInteropRootInternal(uint256 chainId, uint256 blockOrBatchNumber, bytes32[] calldata sides) internal {
        // In the current code sides should only contain the Interop Root itself, as mentioned above.
        if (sides.length != 1) {
            revert SidesLengthNotOne();
        }
        if (sides[0] == bytes32(0)) {
            revert MessageRootIsZero();
        }

        // Make sure that interopRoots for specified chainId and blockOrBatchNumber wasn't set already.
        if (interopRoots[chainId][blockOrBatchNumber] != bytes32(0)) {
            revert InteropRootAlreadyExists();
        }

        // Set interopRoots for specified chainId and blockOrBatchNumber.
        interopRoots[chainId][blockOrBatchNumber] = sides[0];

        // Emit event.
        emit InteropRootAdded(chainId, blockOrBatchNumber, sides);
    }

    function _addSingleInteropRootInternal(InteropRoot calldata interopRoot) internal {
        _addInteropRootInternal(interopRoot.chainId, interopRoot.blockOrBatchNumber, interopRoot.sides);
    }

    function _addInteropRootsInBatchInternal(InteropRoot[] calldata interopRootsInput) internal {
        unchecked {
            uint256 amountOfRoots = interopRootsInput.length;
            for (uint256 i; i < amountOfRoots; ++i) {
                _addInteropRootInternal(
                    interopRootsInput[i].chainId,
                    interopRootsInput[i].blockOrBatchNumber,
                    interopRootsInput[i].sides
                );
            }
        }
    }
}

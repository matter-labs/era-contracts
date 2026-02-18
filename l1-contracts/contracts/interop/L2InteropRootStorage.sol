// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {IL2InteropRootStorage} from "./IL2InteropRootStorage.sol";
import {SidesLengthNotOne, InteropRootAlreadyExists, MessageRootIsZero} from "./InteropErrors.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice InteropRootStorage contract responsible for storing the message roots of other chains on the L2.
 */
contract L2InteropRootStorage is IL2InteropRootStorage {
    /// @notice Modifier that makes sure that the method
    /// can only be called from the bootloader.
    modifier onlyCallFromBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Mapping of chain ID to block or batch number to message root.
    mapping(uint256 chainId => mapping(uint256 blockOrBatchNumber => bytes32 interopRoot)) public interopRoots;

    /// @dev Adds a message root to the L2InteropRootStorage contract.
    /// @dev For both proof-based and commit-based interop, the `sides` parameter contains only the root.
    /// @dev Once pre-commit interop is introduced, `sides` will include both the root and its associated sides.
    /// @dev This interface is preserved now so that enabling pre-commit interop later requires no changes in interface.
    /// @dev In proof-based and pre-commit interop, `blockOrBatchNumber` represents the block number, in commit-based interop,
    /// it represents the batch number. This distinction reflects the implementation requirements  of each interop finality form.
    /// @dev Note: should be removed in the next protocol version.
    /// @param chainId The chain ID of the chain that the message root is for.
    /// @param blockOrBatchNumber The block or batch number of the message root. Either of block number or batch number will be used,
    /// depends on finality form of interop, mentioned above.
    /// @param sides The message root sides. Note, that `sides` here are coming from `DynamicIncrementalMerkle` nomenclature.
    function addInteropRoot(
        uint256 chainId,
        uint256 blockOrBatchNumber,
        bytes32[] calldata sides
    ) external onlyCallFromBootloader {
        _addInteropRoot(chainId, blockOrBatchNumber, sides);
    }

    /// @dev Adds a message root to the L2InteropRootStorage contract.
    /// @dev Currently duplicates `addInteropRoot` for backward compatibility.
    /// @param interopRoot The interop root to be added. See the description of the corresponding struct above.
    function addSingleInteropRoot(InteropRoot calldata interopRoot) external onlyCallFromBootloader {
        _addInteropRoot(interopRoot.chainId, interopRoot.blockOrBatchNumber, interopRoot.sides);
    }

    /// @dev Adds a group of interop roots to the L2InteropRootStorage contract.
    /// @param interopRootsInput The array of interop roots to be added. See the description of the corresponding struct above.
    function addInteropRootsInBatch(InteropRoot[] calldata interopRootsInput) external onlyCallFromBootloader {
        unchecked {
            uint256 amountOfRoots = interopRootsInput.length;
            for (uint256 i; i < amountOfRoots; ++i) {
                _addInteropRoot(
                    interopRootsInput[i].chainId,
                    interopRootsInput[i].blockOrBatchNumber,
                    interopRootsInput[i].sides
                );
            }
        }
    }

    function _addInteropRoot(uint256 chainId, uint256 blockOrBatchNumber, bytes32[] calldata sides) private {
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

        // Set interopRoots for specified chainId and blockOrBatchNumber, emit event.
        interopRoots[chainId][blockOrBatchNumber] = sides[0];

        emit InteropRootAdded(chainId, blockOrBatchNumber, sides);
    }
}

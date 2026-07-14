// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {IL2InteropRootStorage} from "./IL2InteropRootStorage.sol";
import {InteropRootAlreadyExists, SidesLengthNotOne} from "./InteropErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";

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

    /// @notice Mapping of chain ID to block or batch number to the imported message root and its
    /// creation timestamp, i.e. the storage holds `(blockOrBatchNumber, root, timestamp)` tuples per
    /// chain. The tuple is double checked on the settlement layer during batch execution (see
    /// `ExecutorFacet._verifyDependencyInteropRoots`), so time-sensitive proofs (e.g. the
    /// atomic-interop timeout protocol) can rely on the timestamp as much as on the root itself.
    /// @dev The timestamp is zero when the root was imported through the timestamp-less
    /// `addInteropRoot` entry point (used by the EraVM bootloader). No roots recorded under previous
    /// protocol versions exist: interop was not activated in v31.
    /// @dev Note on storage compatibility with v31: since interop has not been enabled in v31, this
    /// mapping was empty at the time of the upgrade; additionally, mapping values live at hashed
    /// locations, so extending the value type from `bytes32` to a struct (whose first member `root`
    /// occupies exactly the slot the plain `bytes32` used) does not shift any other storage.
    mapping(uint256 chainId => mapping(uint256 blockOrBatchNumber => StoredInteropRoot)) internal storedInteropRoots;

    /// @notice Returns the imported `(root, timestamp)` tuple for a chain ID and block or batch number.
    function interopRoots(
        uint256 chainId,
        uint256 blockOrBatchNumber
    ) external view returns (StoredInteropRoot memory) {
        return storedInteropRoots[chainId][blockOrBatchNumber];
    }

    /// @dev Adds a message root to the L2InteropRootStorage contract, without a creation timestamp.
    /// @dev For both proof-based and commit-based interop, the `sides` parameter contains only the root.
    /// @dev Once pre-commit interop is introduced, `sides` will include both the root and its associated sides.
    /// @dev This interface is preserved now so that enabling pre-commit interop later requires no changes in interface.
    /// @dev In proof-based and pre-commit interop, `blockOrBatchNumber` represents the block number, in commit-based interop,
    /// it represents the batch number. This distinction reflects the implementation requirements  of each interop finality form.
    /// @dev Note: should be removed in the next protocol version. Roots imported through this legacy
    /// entry point have no timestamp recorded and cannot be used for time-sensitive proofs.
    /// @param chainId The chain ID of the chain that the message root is for.
    /// @param blockOrBatchNumber The block or batch number of the message root. Either of block number or batch number will be used,
    /// depends on finality form of interop, mentioned above.
    /// @param sides The message root sides. Note, that `sides` here are coming from `DynamicIncrementalMerkle` nomenclature.
    function addInteropRoot(
        uint256 chainId,
        uint256 blockOrBatchNumber,
        bytes32[] calldata sides
    ) external onlyCallFromBootloader {
        _addInteropRoot(chainId, blockOrBatchNumber, 0, sides);
    }

    /// @dev Adds a message root to the L2InteropRootStorage contract.
    /// @dev Imports the full `(blockOrBatchNumber, root, timestamp)` tuple; see {InteropRoot}.
    /// @param interopRoot The interop root to be added. See the description of the corresponding struct above.
    function addSingleInteropRoot(InteropRoot calldata interopRoot) external onlyCallFromBootloader {
        _addInteropRoot(interopRoot.chainId, interopRoot.blockOrBatchNumber, interopRoot.timestamp, interopRoot.sides);
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
                    interopRootsInput[i].timestamp,
                    interopRootsInput[i].sides
                );
            }
        }
    }

    function _addInteropRoot(
        uint256 chainId,
        uint256 blockOrBatchNumber,
        uint256 timestamp,
        bytes32[] calldata sides
    ) private {
        // In the current code sides should only contain the Interop Root itself, as mentioned above.
        if (sides.length != 1) {
            revert SidesLengthNotOne();
        }
        if (sides[0] == bytes32(0)) {
            revert MessageRootIsZero();
        }

        // Make sure that interopRoots for specified chainId and blockOrBatchNumber wasn't set already.
        if (storedInteropRoots[chainId][blockOrBatchNumber].root != bytes32(0)) {
            revert InteropRootAlreadyExists();
        }

        // Set interopRoots for specified chainId and blockOrBatchNumber, emit event.
        storedInteropRoots[chainId][blockOrBatchNumber] = StoredInteropRoot({root: sides[0], timestamp: timestamp});

        emit InteropRootAdded(chainId, blockOrBatchNumber, timestamp, sides);
    }
}

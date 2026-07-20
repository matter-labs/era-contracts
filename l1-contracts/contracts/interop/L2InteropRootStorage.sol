// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {Unauthorized} from "contracts/l2-system/zksync-os/errors/ZKOSContractErrors.sol";
import {IL2InteropRootStorage} from "./IL2InteropRootStorage.sol";
import {InteropRootAlreadyExists, InteropRootTimestampIsZero, SidesLengthNotOne} from "./InteropErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Stores the message roots of other chains on the L2, imported by the bootloader.
 * See {protocol-docs/interop.md} (root import).
 */
contract L2InteropRootStorage is IL2InteropRootStorage {
    /// @dev Only allows calls from the bootloader.
    modifier onlyCallFromBootloader() {
        if (msg.sender != L2_BOOTLOADER_ADDRESS) {
            revert Unauthorized(msg.sender);
        }
        _;
    }

    /// @notice Imported `(root, timestamp)` per (chainId, blockOrBatchNumber); the tuple is double
    /// checked on the settlement layer during batch execution, so time-sensitive proofs can rely on
    /// the timestamp as much as on the root. See {protocol-docs/interop.md} (root import).
    /// @dev ZKsync OS only: the EraVM bootloader lacks the timestamp-carrying import entry points.
    /// @dev v31 storage compatibility: the mapping was empty at upgrade time (interop was inactive in
    /// v31) and the struct's first member occupies the old `bytes32` slot, so widening the value type
    /// is layout-safe.
    mapping(uint256 chainId => mapping(uint256 blockOrBatchNumber => StoredInteropRoot)) internal storedInteropRoots;

    /// @inheritdoc IL2InteropRootStorage
    function interopRoots(
        uint256 chainId,
        uint256 blockOrBatchNumber
    ) external view returns (StoredInteropRoot memory) {
        return storedInteropRoots[chainId][blockOrBatchNumber];
    }

    /// @notice Imports a single interop root as a full `(blockOrBatchNumber, root, timestamp)` tuple.
    /// See {protocol-docs/interop.md} (root import) for the `sides` and block-vs-batch-number
    /// semantics.
    /// @param interopRoot The interop root to be added; see {InteropRoot}.
    function addSingleInteropRoot(InteropRoot calldata interopRoot) external onlyCallFromBootloader {
        _addInteropRoot(interopRoot.chainId, interopRoot.blockOrBatchNumber, interopRoot.timestamp, interopRoot.sides);
    }

    /// @notice Imports a group of interop roots (see {addSingleInteropRoot}).
    /// @param interopRootsInput The array of interop roots to be added.
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
        // For now `sides` must contain only the interop root itself.
        if (sides.length != 1) {
            revert SidesLengthNotOne();
        }
        if (sides[0] == bytes32(0)) {
            revert MessageRootIsZero();
        }
        // Keeps the {IL2InteropRootStorage} invariant structural: a zero stored timestamp only ever
        // means "nothing imported at this key" (the atomic-interop timeout path relies on it).
        if (timestamp == 0) {
            revert InteropRootTimestampIsZero();
        }

        if (storedInteropRoots[chainId][blockOrBatchNumber].root != bytes32(0)) {
            revert InteropRootAlreadyExists();
        }

        storedInteropRoots[chainId][blockOrBatchNumber] = StoredInteropRoot({root: sides[0], timestamp: timestamp});

        emit InteropRootAdded(chainId, blockOrBatchNumber, timestamp, sides);
    }
}

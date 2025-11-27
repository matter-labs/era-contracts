// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {L2InteropRootStorageBase, InteropRoot} from "./abstract/L2InteropRootStorageBase.sol";

// TODO: where should this live? Also, use a constant + offset.
address constant INTEROP_ROOT_REPORTER_HOOK = address(0x7003);
error InteropRootReporterHookFailed();
error InteropRootAlreadyAddedThisBlock();

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice InteropRootStorageZKsyncOS contract responsible for storing the message roots of other chains on the L2 for ZKsync OS. Differences with Era are that this contract is only callable once per block by the coinbase and that it reports every new interop root to a ZKsync OS system hook.
 */
contract L2InteropRootStorageZKsyncOS is L2InteropRootStorageBase {
    /// @notice Last L2 block in which interop roots were added via any entrypoint.
    uint256 public lastInteropRootAdditionBlock;

    /// @dev Ensure interop roots can only be added once per block.
    modifier onlyOncePerBlock() {
        if (lastInteropRootAdditionBlock == block.number) {
            revert InteropRootAlreadyAddedThisBlock();
        }
        lastInteropRootAdditionBlock = block.number;
        _;
    }

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
    ) external onlyCallFromCoinbase onlyOncePerBlock {
        _addInteropRootInternal(chainId, blockOrBatchNumber, sides);
    }

    /// @dev Adds a message root to the L2InteropRootStorage contract.
    /// @dev Currently duplicates `addInteropRoot` for backward compatibility.
    /// @param interopRoot The interop root to be added. See the description of the corresponding struct above.
    function addSingleInteropRoot(InteropRoot calldata interopRoot) external onlyCallFromCoinbase onlyOncePerBlock {
        _addSingleInteropRootInternal(interopRoot);
    }

    /// @dev Adds a group of interop roots to the L2InteropRootStorage contract.
    /// @param interopRootsInput The array of interop roots to be added. See the description of the corresponding struct above.
    function addInteropRootsInBatch(
        InteropRoot[] calldata interopRootsInput
    ) external onlyCallFromCoinbase onlyOncePerBlock {
        _addInteropRootsInBatchInternal(interopRootsInput);
    }

    /// @dev ZKsync OS–specific hook: report to INTEROP_ROOT_REPORTER_HOOK.
    function _afterInteropRootAdded(uint256 chainId, uint256 blockOrBatchNumber, bytes32 root) internal override {
        // Binary layout:
        // [ 0..31] chainId
        // [32..63] blockOrBatchNumber
        // [64..95] root
        bytes memory message = abi.encodePacked(chainId, blockOrBatchNumber, root);

        (bool ok, ) = INTEROP_ROOT_REPORTER_HOOK.call(message);
        if (!ok) {
            revert InteropRootReporterHookFailed();
        }
    }
}

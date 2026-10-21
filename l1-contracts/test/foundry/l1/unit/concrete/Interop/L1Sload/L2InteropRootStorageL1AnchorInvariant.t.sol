// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {L1_BLOCK_HASH_IMPORT_ID} from "contracts/common/Config.sol";
import {StoredInteropRoot} from "contracts/common/Messaging.sol";
import {L1AnchorNotNewer} from "contracts/interop/InteropErrors.sol";
import {L2_BOOTLOADER_ADDRESS, L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadMockUtils} from "./L1SloadMockUtils.sol";

/// @dev Imports random anchors through the bootloader entry point and tracks the newest accepted one.
contract L2AnchorImportHandler is Test {
    L2InteropRootStorage internal constant ROOT_STORAGE = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

    uint256 public newestBlock;
    bytes32 public newestHash;
    uint256 public refused;

    function importAnchor(uint64 _blockNumber, uint64 _timestamp) external {
        uint256 blockNumber = _blockNumber;
        uint256 timestamp = bound(_timestamp, 1, type(uint64).max);
        bytes32 blockHash = keccak256(abi.encode("l1 block", blockNumber));

        if (blockNumber <= newestBlock) {
            vm.prank(L2_BOOTLOADER_ADDRESS);
            vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, blockNumber, newestBlock));
            ROOT_STORAGE.addSingleInteropRoot(L1SloadMockUtils.anchorRoot(blockNumber, blockHash, timestamp));
            ++refused;
            return;
        }
        L1SloadMockUtils.importAnchor(blockNumber, blockHash, timestamp);
        newestBlock = blockNumber;
        newestHash = blockHash;
    }

    /// @dev Imports the next block, so that runs don't stall on one huge block number.
    function importNextAnchor(uint64 _timestamp) external {
        uint256 blockNumber = newestBlock + 1;
        bytes32 blockHash = keccak256(abi.encode("l1 block", blockNumber));
        L1SloadMockUtils.importAnchor(blockNumber, blockHash, bound(_timestamp, 1, type(uint64).max));
        newestBlock = blockNumber;
        newestHash = blockHash;
    }
}

/// @notice The L1SLOAD anchor only moves forward, and is never a message root.
/// See {protocol-docs/l1sload.md#anchors}.
contract L2InteropRootStorageL1AnchorInvariantTest is Test {
    L2InteropRootStorage internal constant ROOT_STORAGE = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

    L2AnchorImportHandler internal handler;
    uint256 internal lastSeen;

    function setUp() public {
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
        handler = new L2AnchorImportHandler();
        targetContract(address(handler));
    }

    function invariant_anchorIsTheNewestImport() public view {
        assertEq(ROOT_STORAGE.l1AnchorBlockNumber(), handler.newestBlock());
        assertEq(ROOT_STORAGE.l1AnchorBlockHash(), handler.newestHash());
    }

    function invariant_anchorNeverMovesBack() public {
        uint256 current = ROOT_STORAGE.l1AnchorBlockNumber();
        assertGe(current, lastSeen);
        lastSeen = current;
    }

    function invariant_anchorIsNotAMessageRoot() public view {
        StoredInteropRoot memory stored = ROOT_STORAGE.interopRoots(L1_BLOCK_HASH_IMPORT_ID, handler.newestBlock());
        assertEq(stored.root, bytes32(0));
        assertEq(stored.timestamp, 0);
    }
}

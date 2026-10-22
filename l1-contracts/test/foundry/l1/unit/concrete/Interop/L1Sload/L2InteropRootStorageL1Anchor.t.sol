// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {InteropRoot} from "contracts/common/Messaging.sol";
import {
    L1_BLOCK_HASH_IMPORT_ID,
    L1SLOAD_ANCHOR_BLOCK_HASH_SLOT,
    L1SLOAD_ANCHOR_TIMESTAMP_SLOT
} from "contracts/common/Config.sol";
import {L1AnchorNotNewer} from "contracts/interop/InteropErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {L2_BOOTLOADER_ADDRESS, L2_INTEROP_ROOT_STORAGE_ADDR} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadMockUtils} from "./L1SloadMockUtils.sol";

/// @notice Anchor imports through `L2InteropRootStorage`. See {protocol-docs/l1sload.md#anchors}.
contract L2InteropRootStorageL1AnchorTest is Test {
    L2InteropRootStorage internal rootStorage = L2InteropRootStorage(L2_INTEROP_ROOT_STORAGE_ADDR);

    function setUp() public {
        vm.etch(L2_INTEROP_ROOT_STORAGE_ADDR, address(new L2InteropRootStorage()).code);
    }

    /// @dev ZKsync OS reads these slots directly.
    function test_anchorSlotsMatchTheOS() public pure {
        assertEq(L1SLOAD_ANCHOR_BLOCK_HASH_SLOT, 0x142c4a6779611c44dc597e02ef1171577327f02356cebd6f373cfaa886831283);
        assertEq(L1SLOAD_ANCHOR_TIMESTAMP_SLOT, 0x840528b13813a4d88e7572e39ead87b5d3a2ef4d72fc74665e1c19c022e232ce);
    }

    /// @dev The import moves the anchor and emits the root event, but stores nothing as a message root.
    function test_importSetsAnchor() public {
        bytes32[] memory sides = new bytes32[](1);
        sides[0] = keccak256("block 100");
        vm.expectEmit(L2_INTEROP_ROOT_STORAGE_ADDR);
        emit IL2InteropRootStorage.InteropRootAdded(L1_BLOCK_HASH_IMPORT_ID, 100, 1_000, sides);
        L1SloadMockUtils.importAnchor(100, sides[0], 1_000);

        assertEq(rootStorage.l1AnchorBlockHash(), sides[0]);
        assertEq(rootStorage.l1AnchorBlockNumber(), 100);
        assertEq(rootStorage.l1AnchorTimestamp(), 1_000);
        assertEq(vm.load(L2_INTEROP_ROOT_STORAGE_ADDR, L1SLOAD_ANCHOR_BLOCK_HASH_SLOT), sides[0]);
        assertEq(rootStorage.interopRoots(L1_BLOCK_HASH_IMPORT_ID, 100).root, bytes32(0));
        assertEq(rootStorage.latestInteropRootTimestamp(L1_BLOCK_HASH_IMPORT_ID), 0);
    }

    /// @dev Each import moves the anchor to a strictly higher block or reverts; block 0 means "no anchor".
    function testFuzz_anchorOnlyMovesForward(uint64[4] memory _blockNumbers) public {
        uint256 highest;
        for (uint256 i = 0; i < _blockNumbers.length; ++i) {
            uint256 blockNumber = _blockNumbers[i];
            bytes32 blockHash = keccak256(abi.encode(blockNumber));
            if (blockNumber > highest) {
                L1SloadMockUtils.importAnchor(blockNumber, blockHash, 1_000 + i);
                highest = blockNumber;
            } else {
                vm.prank(L2_BOOTLOADER_ADDRESS);
                vm.expectRevert(abi.encodeWithSelector(L1AnchorNotNewer.selector, blockNumber, highest));
                rootStorage.addSingleInteropRoot(L1SloadMockUtils.anchorRoot(blockNumber, blockHash, 1_000 + i));
            }
            assertEq(rootStorage.l1AnchorBlockNumber(), highest);
        }
    }

    /// @dev The usual import checks still apply.
    function test_revertWhen_anchorHashIsZero() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(MessageRootIsZero.selector);
        rootStorage.addSingleInteropRoot(L1SloadMockUtils.anchorRoot(100, bytes32(0), 1_000));
    }

    function test_otherChainRootsDoNotMoveAnchor() public {
        InteropRoot memory chainRoot = L1SloadMockUtils.anchorRoot(200, keccak256("root"), 1_000);
        chainRoot.chainId = 1;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(chainRoot);

        assertEq(rootStorage.l1AnchorBlockNumber(), 0);
        assertEq(rootStorage.interopRoots(1, 200).root, keccak256("root"));
    }
}

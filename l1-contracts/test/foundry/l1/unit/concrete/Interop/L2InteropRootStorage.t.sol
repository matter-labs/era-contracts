// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropRootStorage} from "contracts/interop/L2InteropRootStorage.sol";
import {IL2InteropRootStorage} from "contracts/interop/IL2InteropRootStorage.sol";
import {InteropRoot, StoredInteropRoot} from "contracts/common/Messaging.sol";
import {
    InteropRootAlreadyExists,
    InteropRootTimestampIsZero,
    SidesLengthNotOne
} from "contracts/interop/InteropErrors.sol";
import {MessageRootIsZero} from "contracts/state-transition/L1StateTransitionErrors.sol";
import {L2_BOOTLOADER_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

/// @notice Covers the `L2InteropRootStorage` import gates: the `(root, timestamp)` tuple is stored and
/// malformed imports are rejected, keeping the {IL2InteropRootStorage} zero-timestamp invariant
/// structural. See {protocol-docs/message-root.md#interop-root-import-and-the-batch-execution-double-check}.
contract L2InteropRootStorageTest is Test {
    uint256 internal constant CHAIN_ID = 320;
    uint256 internal constant BLOCK_NUMBER = 7;
    uint256 internal constant TIMESTAMP = 1_700_000_000;

    L2InteropRootStorage internal rootStorage;

    function setUp() public {
        rootStorage = new L2InteropRootStorage();
    }

    function _root(uint256 _timestamp, bytes32 _side) internal pure returns (InteropRoot memory interopRoot) {
        interopRoot.chainId = CHAIN_ID;
        interopRoot.blockOrBatchNumber = BLOCK_NUMBER;
        interopRoot.timestamp = _timestamp;
        interopRoot.sides = new bytes32[](1);
        interopRoot.sides[0] = _side;
    }

    function test_addSingleInteropRoot_storesTupleAndEmits() public {
        InteropRoot memory interopRoot = _root(TIMESTAMP, keccak256("root"));

        vm.expectEmit(true, true, false, true, address(rootStorage));
        emit IL2InteropRootStorage.InteropRootAdded(CHAIN_ID, BLOCK_NUMBER, TIMESTAMP, interopRoot.sides);
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(interopRoot);

        StoredInteropRoot memory stored = rootStorage.interopRoots(CHAIN_ID, BLOCK_NUMBER);
        assertEq(stored.root, interopRoot.sides[0]);
        assertEq(stored.timestamp, TIMESTAMP);
    }

    function test_RevertWhen_timestampIsZero() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(InteropRootTimestampIsZero.selector);
        rootStorage.addSingleInteropRoot(_root(0, keccak256("root")));
    }

    function test_RevertWhen_rootIsZero() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(MessageRootIsZero.selector);
        rootStorage.addSingleInteropRoot(_root(TIMESTAMP, bytes32(0)));
    }

    function test_RevertWhen_alreadyImported() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(_root(TIMESTAMP, keccak256("root")));

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(InteropRootAlreadyExists.selector);
        rootStorage.addSingleInteropRoot(_root(TIMESTAMP + 1, keccak256("other")));
    }

    /// @notice The tracked latest timestamp is the MAXIMUM over all imports for the chain — imports
    /// need not arrive in timestamp order, and the value must never decrease (the atomic-interop send
    /// path relies on its monotonicity to keep expired flows closed for good).
    function test_latestInteropRootTimestamp_tracksMaximumAcrossImports() public {
        assertEq(rootStorage.latestInteropRootTimestamp(CHAIN_ID), 0, "no import yet");

        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(_root(TIMESTAMP, keccak256("root")));
        assertEq(rootStorage.latestInteropRootTimestamp(CHAIN_ID), TIMESTAMP);

        // A fresher root bumps the tracked value.
        InteropRoot memory fresher = _root(TIMESTAMP + 100, keccak256("fresher"));
        fresher.blockOrBatchNumber = BLOCK_NUMBER + 1;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(fresher);
        assertEq(rootStorage.latestInteropRootTimestamp(CHAIN_ID), TIMESTAMP + 100);

        // An out-of-order (older) root must NOT lower it.
        InteropRoot memory older = _root(TIMESTAMP + 50, keccak256("older"));
        older.blockOrBatchNumber = BLOCK_NUMBER + 2;
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(older);
        assertEq(rootStorage.latestInteropRootTimestamp(CHAIN_ID), TIMESTAMP + 100, "maximum must be kept");
    }

    /// @notice Tracking is per chain id: an import for one chain leaves other chains' values untouched.
    function test_latestInteropRootTimestamp_isPerChain() public {
        vm.prank(L2_BOOTLOADER_ADDRESS);
        rootStorage.addSingleInteropRoot(_root(TIMESTAMP, keccak256("root")));

        assertEq(rootStorage.latestInteropRootTimestamp(CHAIN_ID + 1), 0);
    }

    function test_RevertWhen_sidesLengthNotOne() public {
        InteropRoot memory interopRoot = _root(TIMESTAMP, keccak256("root"));
        interopRoot.sides = new bytes32[](2);
        interopRoot.sides[0] = keccak256("root");
        interopRoot.sides[1] = keccak256("side");

        vm.prank(L2_BOOTLOADER_ADDRESS);
        vm.expectRevert(SidesLengthNotOne.selector);
        rootStorage.addSingleInteropRoot(interopRoot);
    }
}

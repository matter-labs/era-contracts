// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {Test} from "forge-std/Test.sol";

import {L2InteropCommitmentTree} from "contracts/atomic-interop/L2InteropCommitmentTree.sol";
import {MockInteropCommitmentLeafHook} from "contracts/dev-contracts/MockInteropCommitmentLeafHook.sol";
import {
    L2_ATOMIC_FLOW_MANAGER_ADDR,
    L2_COMPLEX_UPGRADER_ADDR,
    INTEROP_COMMITMENT_LEAF_HOOK
} from "contracts/common/l2-helpers/L2ContractAddresses.sol";
import {InteropCommitmentLeafHookFailed} from "contracts/atomic-interop/AtomicInteropErrors.sol";

/// @notice Verifies that every {L2InteropCommitmentTree-insert} reports the inserted value to the
/// interop commitment leaf system hook (0x7004), so the inserted values — and therefore the whole
/// tree — stay reconstructible from L1 DA. The hook is a ZKsync OS system address; in the foundry
/// environment we etch a mock at it to capture the calldata.
contract L2InteropCommitmentTreeHookTest is Test {
    L2InteropCommitmentTree internal tree;
    MockInteropCommitmentLeafHook internal hook;

    function setUp() public {
        tree = new L2InteropCommitmentTree();

        // Etch the mock at the well-known hook address.
        MockInteropCommitmentLeafHook mockImpl = new MockInteropCommitmentLeafHook();
        vm.etch(INTEROP_COMMITMENT_LEAF_HOOK, address(mockImpl).code);
        hook = MockInteropCommitmentLeafHook(payable(INTEROP_COMMITMENT_LEAF_HOOK));

        vm.prank(L2_COMPLEX_UPGRADER_ADDR);
        tree.initL2();
    }

    /// @notice `insert` calls the hook exactly once with the 32-byte inserted value as calldata.
    function test_insert_reportsValueToHook() public {
        uint256 value = uint256(keccak256("commit-value-1"));

        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree.insert(value, 0);

        assertEq(hook.callCount(), 1, "hook must be called once per insert");
        assertEq(hook.lastCalldata(), abi.encodePacked(value), "hook calldata must be the 32-byte value");
        assertEq(hook.lastCalldata().length, 32, "hook calldata must be exactly 32 bytes");
    }

    /// @notice Every insert produces its own hook call, in insertion order.
    function test_insert_reportsEachValue() public {
        uint256 value1 = uint256(keccak256("commit-value-1"));
        uint256 value2 = uint256(keccak256("commit-value-2"));

        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree.insert(value1, 0);
        assertEq(hook.callCount(), 1);
        assertEq(hook.lastCalldata(), abi.encodePacked(value1));

        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        tree.insert(value2, 0);
        assertEq(hook.callCount(), 2);
        assertEq(hook.lastCalldata(), abi.encodePacked(value2));
    }

    /// @notice If the hook reverts, the whole insert reverts, keeping the IMT state and the DA log
    /// stream in sync.
    function test_insert_revertsWhenHookFails() public {
        // A hook address whose code reverts on any call.
        vm.etch(INTEROP_COMMITMENT_LEAF_HOOK, hex"fe"); // INVALID opcode

        vm.prank(L2_ATOMIC_FLOW_MANAGER_ADDR);
        vm.expectRevert(InteropCommitmentLeafHookFailed.selector);
        tree.insert(uint256(keccak256("commit-value-1")), 0);
    }
}

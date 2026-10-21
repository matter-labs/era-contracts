// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1Reads} from "contracts/common/l2-helpers/L1Reads.sol";
import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {L1SloadFailed, L1SloadInvalidKeyCount} from "contracts/common/L1ContractErrors.sol";
import {L1SLOAD_MAX_KEYS} from "contracts/common/Config.sol";
import {L1SLOAD_PRECOMPILE_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @dev Exposes the internal library functions.
contract L1ReadsHarness {
    function l1sload(address _l1Contract, bytes32 _key) external view returns (bytes32) {
        return L1Reads.l1sload(_l1Contract, _key);
    }

    function l1sloadMany(address _l1Contract, bytes32[] memory _keys) external view returns (bytes32[] memory) {
        return L1Reads.l1sload(_l1Contract, _keys);
    }

    function isInteropActive(address _l1MessageRoot, uint256 _chainId, uint256 _other) external view returns (bool) {
        return L1View.isInteropActive(_l1MessageRoot, _chainId, _other);
    }
}

/// @notice `L1Reads` and `L1View` against the real L1 contracts. See {protocol-docs/l1sload.md#reading-l1-state}.
contract L1ReadsTest is L1SloadSharedTest {
    L1ReadsHarness internal harness;

    function setUp() public override {
        super.setUp();
        harness = new L1ReadsHarness();
    }

    function test_revertWhen_noAnchor() public {
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, address(l1MessageRoot)));
        harness.l1sload(address(l1MessageRoot), L1View.interopEnabledSlot(CHAIN_ID));
    }

    function test_readsOneSlot() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        assertEq(harness.l1sload(address(l1MessageRoot), L1View.interopEnabledSlot(CHAIN_ID)), bytes32(0));

        _enableInterop(CHAIN_ID);
        assertEq(harness.l1sload(address(l1MessageRoot), L1View.interopEnabledSlot(CHAIN_ID)), bytes32(uint256(1)));
    }

    /// @dev Values come back in the order of the keys.
    function test_readsManySlotsInOrder() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        _enableInterop(PEER_CHAIN_ID);
        _suspendInterop(CHAIN_ID);

        bytes32[] memory keys = new bytes32[](L1SLOAD_MAX_KEYS);
        keys[0] = L1View.interopEnabledSlot(CHAIN_ID);
        keys[1] = L1View.interopSuspendedSlot(CHAIN_ID);
        keys[2] = L1View.interopEnabledSlot(PEER_CHAIN_ID);
        keys[3] = L1View.interopSuspendedSlot(PEER_CHAIN_ID);
        keys[4] = bytes32(0);
        bytes32[] memory values = harness.l1sloadMany(address(l1MessageRoot), keys);

        assertEq(values.length, keys.length);
        assertEq(values[0], bytes32(0));
        assertEq(values[1], bytes32(uint256(1)));
        assertEq(values[2], bytes32(uint256(1)));
        assertEq(values[3], bytes32(0));
        assertEq(values[4], vm.load(address(l1MessageRoot), bytes32(0)), "slot 0 is read as is");
    }

    function test_revertWhen_noKeys() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, 0));
        harness.l1sloadMany(address(l1MessageRoot), new bytes32[](0));
    }

    function test_revertWhen_tooManyKeys() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, L1SLOAD_MAX_KEYS + 1));
        harness.l1sloadMany(address(l1MessageRoot), new bytes32[](L1SLOAD_MAX_KEYS + 1));
    }

    /// @dev A precompile that answers with the wrong length is a failed read, not a short answer.
    function test_revertWhen_outputLengthIsWrong() public {
        // STOP: succeeds with empty output.
        vm.etch(L1SLOAD_PRECOMPILE_ADDRESS, hex"00");
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, address(l1MessageRoot)));
        harness.l1sload(address(l1MessageRoot), L1View.interopEnabledSlot(CHAIN_ID));
    }

    function test_isInteropActive() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        assertFalse(harness.isInteropActive(address(l1MessageRoot), CHAIN_ID, PEER_CHAIN_ID));

        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        assertTrue(harness.isInteropActive(address(l1MessageRoot), CHAIN_ID, PEER_CHAIN_ID));

        _suspendInterop(CHAIN_ID);
        assertFalse(harness.isInteropActive(address(l1MessageRoot), CHAIN_ID, PEER_CHAIN_ID));
        assertFalse(harness.isInteropActive(address(l1MessageRoot), PEER_CHAIN_ID, CHAIN_ID), "symmetric");
    }
}

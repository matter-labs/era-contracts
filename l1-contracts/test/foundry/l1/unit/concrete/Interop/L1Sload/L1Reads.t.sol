// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1Reads} from "contracts/common/l2-helpers/L1Reads.sol";
import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {L1AnchorStale, L1SloadFailed, L1SloadInvalidKeyCount} from "contracts/common/L1ContractErrors.sol";
import {L1_ANCHOR_MAX_LAG, L1SLOAD_MAX_KEYS} from "contracts/common/Config.sol";
import {L1SLOAD_PRECOMPILE_ADDRESS} from "contracts/common/l2-helpers/L2ContractAddresses.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

contract L1ReadsHarness {
    function l1sload(address _l1Contract, bytes32[] memory _keys) external view returns (bytes32[] memory) {
        return L1Reads.l1sload(_l1Contract, _keys);
    }

    function isReceiveAllowed(address _crs, uint256 _chainId, uint256 _peerChainId) external view returns (bool) {
        return L1View.isReceiveAllowed(_crs, _chainId, _peerChainId);
    }
}

/// @notice `L1Reads` and the `L1View` freshness rule, see {protocol-docs/l1sload.md#freshness}. The gating
/// semantics of `L1View` are covered through `L2Bridgehub` in `L2BridgehubL1Reads.t.sol`.
contract L1ReadsTest is L1SloadSharedTest {
    uint256 internal constant ANCHORED_AT = 1_700_000_000;

    L1ReadsHarness internal harness;
    address internal crs;

    function setUp() public override {
        super.setUp();
        harness = new L1ReadsHarness();
        crs = address(chainRegistrationSender);
        vm.warp(ANCHORED_AT);
    }

    function test_revertWhen_noAnchor() public {
        vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, 0, ANCHORED_AT));
        harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID);

        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, crs));
        harness.l1sload(crs, _oneKey(L1View.interopSuspendedSlot(CHAIN_ID)));
    }

    /// @dev Both `L1View` and the precompile refuse reads exactly past the lag.
    function testFuzz_readsFailPastTheLag(uint256 _age) public {
        _importL1Anchor(1, keccak256("anchor"), ANCHORED_AT);
        uint256 age = bound(_age, 0, 10 * L1_ANCHOR_MAX_LAG);
        vm.warp(ANCHORED_AT + age);

        if (age > L1_ANCHOR_MAX_LAG) {
            vm.expectRevert(abi.encodeWithSelector(L1AnchorStale.selector, ANCHORED_AT, ANCHORED_AT + age));
            harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID);
            vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, crs));
            harness.l1sload(crs, _oneKey(L1View.interopSuspendedSlot(CHAIN_ID)));
        } else {
            harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID);
            harness.l1sload(crs, _oneKey(L1View.interopSuspendedSlot(CHAIN_ID)));
        }
    }

    /// @dev ZKsync OS saturates `anchorTimestamp + L1_ANCHOR_MAX_LAG`, so an anchor whose sum would overflow reads as
    /// fresh on both paths.
    function test_freshnessSaturates() public {
        _importL1Anchor(1, keccak256("anchor"), type(uint256).max - L1_ANCHOR_MAX_LAG + 1);

        assertFalse(harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID));
        assertEq(harness.l1sload(crs, _oneKey(L1View.interopSuspendedSlot(CHAIN_ID)))[0], bytes32(0));
    }

    function test_readsManySlotsInOrder() public {
        _allowBothWays(CHAIN_ID, PEER_CHAIN_ID);
        _suspendInterop(PEER_CHAIN_ID);
        _importL1Anchor(1, keccak256("anchor"), ANCHORED_AT);

        bytes32[] memory keys = new bytes32[](L1SLOAD_MAX_KEYS);
        keys[0] = L1View.interopPeerAllowedSlot(CHAIN_ID, PEER_CHAIN_ID);
        keys[1] = L1View.interopSuspendedSlot(CHAIN_ID);
        keys[2] = L1View.interopSuspendedSlot(PEER_CHAIN_ID);
        keys[3] = L1View.interopBaseTokenAssetIdSlot(PEER_CHAIN_ID);
        keys[4] = L1View.interopBaseTokenAssetIdSlot(CHAIN_ID);
        bytes32[] memory values = harness.l1sload(crs, keys);

        assertEq(values.length, keys.length);
        assertEq(values[0], bytes32(uint256(1)));
        assertEq(values[1], bytes32(0));
        assertEq(values[2], bytes32(uint256(1)));
        assertEq(values[3], _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(values[4], _baseTokenAssetId(CHAIN_ID));
    }

    function test_revertWhen_invalidKeyCount() public {
        _importL1Anchor(1, keccak256("anchor"), ANCHORED_AT);

        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, 0));
        harness.l1sload(crs, new bytes32[](0));

        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, L1SLOAD_MAX_KEYS + 1));
        harness.l1sload(crs, new bytes32[](L1SLOAD_MAX_KEYS + 1));
    }

    /// @dev A precompile answering with the wrong length is a failed read, not a short answer.
    function test_revertWhen_outputLengthIsWrong() public {
        // STOP: succeeds with empty output.
        vm.etch(L1SLOAD_PRECOMPILE_ADDRESS, hex"00");
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, crs));
        harness.l1sload(crs, _oneKey(L1View.interopSuspendedSlot(CHAIN_ID)));
    }

    function _oneKey(bytes32 _key) internal pure returns (bytes32[] memory keys) {
        keys = new bytes32[](1);
        keys[0] = _key;
    }
}

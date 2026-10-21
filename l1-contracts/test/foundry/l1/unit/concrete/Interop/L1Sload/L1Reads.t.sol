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

    function isReceiveAllowed(address _crs, uint256 _chainId, uint256 _peerChainId) external view returns (bool) {
        return L1View.isReceiveAllowed(_crs, _chainId, _peerChainId);
    }

    function sendTarget(address _crs, uint256 _chainId, uint256 _peerChainId) external view returns (bool, bytes32) {
        return L1View.sendTarget(_crs, _chainId, _peerChainId);
    }

    function baseTokenAssetId(address _crs, uint256 _chainId) external view returns (bytes32) {
        return L1View.baseTokenAssetId(_crs, _chainId);
    }
}

/// @notice `L1Reads` and `L1View` against the real L1 `ChainRegistrationSender`.
/// See {protocol-docs/l1sload.md#reading-l1-state}.
contract L1ReadsTest is L1SloadSharedTest {
    L1ReadsHarness internal harness;
    address internal crs;

    function setUp() public override {
        super.setUp();
        harness = new L1ReadsHarness();
        crs = address(chainRegistrationSender);
    }

    /*//////////////////////////////////////////////////////////////
                                L1Reads
    //////////////////////////////////////////////////////////////*/

    function test_revertWhen_noAnchor() public {
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, crs));
        harness.l1sload(crs, L1View.interopSuspendedSlot(CHAIN_ID));
    }

    function test_readsOneSlot() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        assertEq(harness.l1sload(crs, L1View.interopSuspendedSlot(CHAIN_ID)), bytes32(0));

        _suspendInterop(CHAIN_ID);
        assertEq(harness.l1sload(crs, L1View.interopSuspendedSlot(CHAIN_ID)), bytes32(uint256(1)));
    }

    /// @dev Values come back in the order of the keys.
    function test_readsManySlotsInOrder() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        _suspendInterop(PEER_CHAIN_ID);

        bytes32[] memory keys = new bytes32[](L1SLOAD_MAX_KEYS);
        keys[0] = L1View.interopPeerAllowedSlot(CHAIN_ID, PEER_CHAIN_ID);
        keys[1] = L1View.interopSuspendedSlot(CHAIN_ID);
        keys[2] = L1View.interopSuspendedSlot(PEER_CHAIN_ID);
        keys[3] = L1View.interopBaseTokenAssetIdSlot(PEER_CHAIN_ID);
        keys[4] = bytes32(uint256(51));
        bytes32[] memory values = harness.l1sloadMany(crs, keys);

        assertEq(values.length, keys.length);
        assertEq(values[0], bytes32(uint256(1)));
        assertEq(values[1], bytes32(0));
        assertEq(values[2], bytes32(uint256(1)));
        assertEq(values[3], _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(values[4], bytes32(uint256(uint160(governance))), "slot 51, the owner, is read as is");
    }

    function test_revertWhen_noKeys() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, 0));
        harness.l1sloadMany(crs, new bytes32[](0));
    }

    function test_revertWhen_tooManyKeys() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        vm.expectRevert(abi.encodeWithSelector(L1SloadInvalidKeyCount.selector, L1SLOAD_MAX_KEYS + 1));
        harness.l1sloadMany(crs, new bytes32[](L1SLOAD_MAX_KEYS + 1));
    }

    /// @dev A precompile that answers with the wrong length is a failed read, not a short answer.
    function test_revertWhen_outputLengthIsWrong() public {
        // STOP: succeeds with empty output.
        vm.etch(L1SLOAD_PRECOMPILE_ADDRESS, hex"00");
        vm.expectRevert(abi.encodeWithSelector(L1SloadFailed.selector, crs));
        harness.l1sload(crs, L1View.interopSuspendedSlot(CHAIN_ID));
    }

    /*//////////////////////////////////////////////////////////////
                                L1View
    //////////////////////////////////////////////////////////////*/

    /// @dev Each `L1View` check is one precompile call.
    function test_isReceiveAllowed_isOneRead() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        vm.expectCall(L1SLOAD_PRECOMPILE_ADDRESS, "", 1);
        harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_sendTarget_isOneRead() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        vm.expectCall(L1SLOAD_PRECOMPILE_ADDRESS, "", 1);
        harness.sendTarget(crs, CHAIN_ID, PEER_CHAIN_ID);
    }

    function test_baseTokenAssetId_isOneRead() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        vm.expectCall(L1SLOAD_PRECOMPILE_ADDRESS, "", 1);
        harness.baseTokenAssetId(crs, PEER_CHAIN_ID);
    }

    /// @dev Receiving needs only this chain's allowance; a suspension of either chain refuses it.
    function test_isReceiveAllowed() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        assertFalse(harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID));

        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);
        assertFalse(harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID), "the peer's side does not count");

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID));

        _suspendInterop(CHAIN_ID);
        assertFalse(harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID), "this chain suspended");
        _resumeInterop(CHAIN_ID);
        _suspendInterop(PEER_CHAIN_ID);
        assertFalse(harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID), "the peer suspended");
        _resumeInterop(PEER_CHAIN_ID);
        assertTrue(harness.isReceiveAllowed(crs, CHAIN_ID, PEER_CHAIN_ID));
    }

    /// @dev Sending needs both allowances and no suspension; the peer's base token comes back regardless.
    function test_sendTarget() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        (bool allowed, bytes32 baseTokenAssetId) = harness.sendTarget(crs, CHAIN_ID, PEER_CHAIN_ID);
        assertFalse(allowed);
        assertEq(baseTokenAssetId, bytes32(0), "no chain allowed the peer yet");

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        (allowed, baseTokenAssetId) = harness.sendTarget(crs, CHAIN_ID, PEER_CHAIN_ID);
        assertFalse(allowed, "the peer's admin has not allowed this chain");
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID));

        _allowInteropPeer(PEER_CHAIN_ID, CHAIN_ID);
        (allowed, baseTokenAssetId) = harness.sendTarget(crs, CHAIN_ID, PEER_CHAIN_ID);
        assertTrue(allowed);
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID));

        _suspendInterop(CHAIN_ID);
        (allowed, ) = harness.sendTarget(crs, CHAIN_ID, PEER_CHAIN_ID);
        assertFalse(allowed, "this chain suspended");
        _resumeInterop(CHAIN_ID);
        _suspendInterop(PEER_CHAIN_ID);
        (allowed, baseTokenAssetId) = harness.sendTarget(crs, CHAIN_ID, PEER_CHAIN_ID);
        assertFalse(allowed, "the peer suspended");
        assertEq(baseTokenAssetId, _baseTokenAssetId(PEER_CHAIN_ID), "a suspension keeps the snapshot");
    }

    /// @dev A chain has a snapshot once any chain's admin allowed it, and keeps it after the pair is deregistered.
    function test_baseTokenAssetId() public {
        _importL1Anchor(1, keccak256("anchor"), 1);
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        assertEq(harness.baseTokenAssetId(crs, PEER_CHAIN_ID), bytes32(0));

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        bytes32 snapshot = chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID);
        assertNotEq(snapshot, bytes32(0));
        assertEq(harness.baseTokenAssetId(crs, PEER_CHAIN_ID), snapshot);
        assertEq(harness.baseTokenAssetId(crs, CHAIN_ID), bytes32(0), "the allowing chain gets no snapshot");

        _deregisterInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertEq(harness.baseTokenAssetId(crs, PEER_CHAIN_ID), snapshot);
    }
}

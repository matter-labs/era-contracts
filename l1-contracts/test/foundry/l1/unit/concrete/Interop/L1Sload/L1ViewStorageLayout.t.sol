// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1View} from "contracts/common/l2-helpers/L1View.sol";
import {
    CHAIN_REGISTRATION_SENDER_INTEROP_BASE_TOKEN_ASSET_ID_SLOT,
    CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT,
    CHAIN_REGISTRATION_SENDER_INTEROP_SUSPENDED_SLOT
} from "contracts/common/Config.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice Pins the L1 storage layout that L2 contracts read with L1SLOAD: each value is written through the real
/// `ChainRegistrationSender` entry point and read back at the slot `L1View` computes. A layout change that moves one
/// of these variables fails here instead of silently breaking every L2 reader.
/// See {protocol-docs/l1sload.md#reading-l1-state}.
contract L1ViewStorageLayoutTest is L1SloadSharedTest {
    bytes32 internal constant TRUE_WORD = bytes32(uint256(1));

    /// @dev The values `forge inspect ChainRegistrationSender storageLayout` reports.
    function test_slotConstants() public pure {
        assertEq(CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT, 152);
        assertEq(CHAIN_REGISTRATION_SENDER_INTEROP_SUSPENDED_SLOT, 153);
        assertEq(CHAIN_REGISTRATION_SENDER_INTEROP_BASE_TOKEN_ASSET_ID_SLOT, 154);
    }

    /// @dev The outer key is the chain whose admin decides, the inner key the peer.
    function test_interopPeerAllowedSlot() public {
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        assertTrue(chainRegistrationSender.interopPeerAllowed(CHAIN_ID, PEER_CHAIN_ID));
        assertEq(
            vm.load(address(chainRegistrationSender), L1View.interopPeerAllowedSlot(CHAIN_ID, PEER_CHAIN_ID)),
            TRUE_WORD
        );
        assertEq(
            vm.load(address(chainRegistrationSender), L1View.interopPeerAllowedSlot(PEER_CHAIN_ID, CHAIN_ID)),
            bytes32(0)
        );

        _deregisterInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        assertEq(
            vm.load(address(chainRegistrationSender), L1View.interopPeerAllowedSlot(CHAIN_ID, PEER_CHAIN_ID)),
            bytes32(0)
        );
    }

    function test_interopSuspendedSlot() public {
        _suspendInterop(CHAIN_ID);

        assertTrue(chainRegistrationSender.isInteropSuspended(CHAIN_ID));
        assertEq(vm.load(address(chainRegistrationSender), L1View.interopSuspendedSlot(CHAIN_ID)), TRUE_WORD);
        assertEq(vm.load(address(chainRegistrationSender), L1View.interopSuspendedSlot(PEER_CHAIN_ID)), bytes32(0));

        _resumeInterop(CHAIN_ID);
        assertEq(vm.load(address(chainRegistrationSender), L1View.interopSuspendedSlot(CHAIN_ID)), bytes32(0));
    }

    /// @dev The snapshot is keyed by the allowed peer, not by the chain that allowed it.
    function test_interopBaseTokenAssetIdSlot() public {
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);

        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);

        assertEq(chainRegistrationSender.interopBaseTokenAssetId(PEER_CHAIN_ID), _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(
            vm.load(address(chainRegistrationSender), L1View.interopBaseTokenAssetIdSlot(PEER_CHAIN_ID)),
            _baseTokenAssetId(PEER_CHAIN_ID)
        );
        assertEq(vm.load(address(chainRegistrationSender), L1View.interopBaseTokenAssetIdSlot(CHAIN_ID)), bytes32(0));
    }
}

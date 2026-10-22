// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {L1View} from "contracts/common/l2-helpers/L1View.sol";

import {L1SloadSharedTest} from "./_L1Sload_Shared.t.sol";

/// @notice Pins the `ChainRegistrationSender` slots that L2 contracts read with L1SLOAD: values written through the real
/// entry points must sit at the slots `L1View` computes. See {protocol-docs/l1sload.md#reading-l1-state}.
contract L1ViewStorageLayoutTest is L1SloadSharedTest {
    function test_gatingSlots() public {
        _enableInterop(CHAIN_ID);
        _enableInterop(PEER_CHAIN_ID);
        _allowInteropPeer(CHAIN_ID, PEER_CHAIN_ID);
        _suspendInterop(CHAIN_ID);

        address crs = address(chainRegistrationSender);
        assertEq(vm.load(crs, L1View.interopPeerAllowedSlot(CHAIN_ID, PEER_CHAIN_ID)), bytes32(uint256(1)));
        assertEq(vm.load(crs, L1View.interopPeerAllowedSlot(PEER_CHAIN_ID, CHAIN_ID)), bytes32(0));
        assertEq(vm.load(crs, L1View.interopSuspendedSlot(CHAIN_ID)), bytes32(uint256(1)));
        assertEq(vm.load(crs, L1View.interopSuspendedSlot(PEER_CHAIN_ID)), bytes32(0));
        assertEq(vm.load(crs, L1View.interopBaseTokenAssetIdSlot(PEER_CHAIN_ID)), _baseTokenAssetId(PEER_CHAIN_ID));
        assertEq(vm.load(crs, L1View.interopBaseTokenAssetIdSlot(CHAIN_ID)), bytes32(0));
    }
}

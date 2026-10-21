// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L1Reads} from "./L1Reads.sol";
import {
    CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT,
    L1_MESSAGE_ROOT_INTEROP_ENABLED_SLOT,
    L1_MESSAGE_ROOT_INTEROP_SUSPENDED_SLOT
} from "../Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Reads the interop gating state of the L1 contracts at the chain's L1SLOAD anchor.
/// See {protocol-docs/l1sload.md#reading-l1-state}.
library L1View {
    /// @notice Whether interop is active, i.e. enabled and not suspended, for both chains.
    /// @param _l1MessageRoot The L1 `L1MessageRoot` proxy.
    /// @param _chainId The first chain.
    /// @param _otherChainId The second chain.
    function isInteropActive(
        address _l1MessageRoot,
        uint256 _chainId,
        uint256 _otherChainId
    ) internal view returns (bool) {
        bytes32[] memory keys = new bytes32[](4);
        keys[0] = interopEnabledSlot(_chainId);
        keys[1] = interopSuspendedSlot(_chainId);
        keys[2] = interopEnabledSlot(_otherChainId);
        keys[3] = interopSuspendedSlot(_otherChainId);
        bytes32[] memory values = L1Reads.l1sload(_l1MessageRoot, keys);
        return values[0] != bytes32(0) && values[1] == bytes32(0) && values[2] != bytes32(0) && values[3] == bytes32(0);
    }

    /// @notice Whether the admin of `_chainId` allowed `_peerChainId` as an interop peer on L1.
    /// @param _chainRegistrationSender The L1 `ChainRegistrationSender` proxy.
    /// @param _chainId The chain whose side is read.
    /// @param _peerChainId The peer.
    function isInteropPeerAllowed(
        address _chainRegistrationSender,
        uint256 _chainId,
        uint256 _peerChainId
    ) internal view returns (bool) {
        return L1Reads.l1sload(_chainRegistrationSender, interopPeerAllowedSlot(_chainId, _peerChainId)) != bytes32(0);
    }

    /// @notice The slot of `L1MessageRoot.interopEnabled[_chainId]`.
    function interopEnabledSlot(uint256 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, L1_MESSAGE_ROOT_INTEROP_ENABLED_SLOT));
    }

    /// @notice The slot of `L1MessageRoot.interopSuspended[_chainId]`.
    function interopSuspendedSlot(uint256 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, L1_MESSAGE_ROOT_INTEROP_SUSPENDED_SLOT));
    }

    /// @notice The slot of `ChainRegistrationSender.interopPeerAllowed[_chainId][_peerChainId]`.
    function interopPeerAllowedSlot(uint256 _chainId, uint256 _peerChainId) internal pure returns (bytes32) {
        bytes32 innerMappingSlot = keccak256(abi.encode(_chainId, CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT));
        return keccak256(abi.encode(_peerChainId, innerMappingSlot));
    }
}

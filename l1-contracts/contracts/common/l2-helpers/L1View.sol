// SPDX-License-Identifier: MIT

pragma solidity ^0.8.21;

import {L1Reads} from "./L1Reads.sol";
import {
    CHAIN_REGISTRATION_SENDER_INTEROP_BASE_TOKEN_ASSET_ID_SLOT,
    CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT,
    CHAIN_REGISTRATION_SENDER_INTEROP_SUSPENDED_SLOT
} from "../Config.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Reads the interop gating state of the L1 `ChainRegistrationSender` at the chain's L1SLOAD anchor, one
/// precompile call per check. `interopEnabled` is never read, see {protocol-docs/l1sload.md#reading-l1-state}.
library L1View {
    /// @notice Whether `_chainId` accepts interop from `_peerChainId`: its admin allowed the peer and neither chain is
    /// suspended.
    /// @param _chainRegistrationSender The L1 `ChainRegistrationSender` proxy.
    /// @param _chainId The receiving chain.
    /// @param _peerChainId The sending peer.
    function isReceiveAllowed(
        address _chainRegistrationSender,
        uint256 _chainId,
        uint256 _peerChainId
    ) internal view returns (bool) {
        bytes32[] memory keys = new bytes32[](3);
        keys[0] = interopPeerAllowedSlot(_chainId, _peerChainId);
        keys[1] = interopSuspendedSlot(_chainId);
        keys[2] = interopSuspendedSlot(_peerChainId);
        bytes32[] memory values = L1Reads.l1sload(_chainRegistrationSender, keys);
        return values[0] != bytes32(0) && values[1] == bytes32(0) && values[2] == bytes32(0);
    }

    /// @notice Whether `_chainId` may send interop to `_peerChainId`, and the peer's base token.
    /// @param _chainRegistrationSender The L1 `ChainRegistrationSender` proxy.
    /// @param _chainId The sending chain.
    /// @param _peerChainId The destination peer.
    /// @return allowed Whether both admins allowed each other and neither chain is suspended.
    /// @return peerBaseTokenAssetId The peer's base token snapshot, zero if no chain ever allowed the peer.
    function sendTarget(
        address _chainRegistrationSender,
        uint256 _chainId,
        uint256 _peerChainId
    ) internal view returns (bool allowed, bytes32 peerBaseTokenAssetId) {
        bytes32[] memory keys = new bytes32[](5);
        keys[0] = interopPeerAllowedSlot(_chainId, _peerChainId);
        keys[1] = interopPeerAllowedSlot(_peerChainId, _chainId);
        keys[2] = interopSuspendedSlot(_chainId);
        keys[3] = interopSuspendedSlot(_peerChainId);
        keys[4] = interopBaseTokenAssetIdSlot(_peerChainId);
        bytes32[] memory values = L1Reads.l1sload(_chainRegistrationSender, keys);
        allowed =
            values[0] != bytes32(0) &&
            values[1] != bytes32(0) &&
            values[2] == bytes32(0) &&
            values[3] == bytes32(0);
        peerBaseTokenAssetId = values[4];
    }

    /// @notice The chain's base token snapshot, zero if no chain admin ever allowed it as a peer.
    /// See {protocol-docs/l1sload.md#the-base-token-snapshot}.
    /// @param _chainRegistrationSender The L1 `ChainRegistrationSender` proxy.
    /// @param _chainId The chain.
    function baseTokenAssetId(address _chainRegistrationSender, uint256 _chainId) internal view returns (bytes32) {
        return L1Reads.l1sload(_chainRegistrationSender, interopBaseTokenAssetIdSlot(_chainId));
    }

    /// @notice The slot of `ChainRegistrationSender.interopPeerAllowed[_chainId][_peerChainId]`.
    function interopPeerAllowedSlot(uint256 _chainId, uint256 _peerChainId) internal pure returns (bytes32) {
        bytes32 innerMappingSlot = keccak256(abi.encode(_chainId, CHAIN_REGISTRATION_SENDER_INTEROP_PEER_ALLOWED_SLOT));
        return keccak256(abi.encode(_peerChainId, innerMappingSlot));
    }

    /// @notice The slot of `ChainRegistrationSender.interopSuspended[_chainId]`.
    function interopSuspendedSlot(uint256 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, CHAIN_REGISTRATION_SENDER_INTEROP_SUSPENDED_SLOT));
    }

    /// @notice The slot of `ChainRegistrationSender.interopBaseTokenAssetId[_chainId]`.
    function interopBaseTokenAssetIdSlot(uint256 _chainId) internal pure returns (bytes32) {
        return keccak256(abi.encode(_chainId, CHAIN_REGISTRATION_SENDER_INTEROP_BASE_TOKEN_ASSET_ID_SLOT));
    }
}

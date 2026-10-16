// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainRegistrationSender {
    /// @notice The admin of `chainId` allowed interop with `peerChainId`.
    event InteropPeerAllowed(uint256 indexed chainId, uint256 indexed peerChainId);

    /// @notice Governance removed `chainId` from the L2 Bridgehub of `chainRegisteredOn`.
    event InteropPairDeregistered(uint256 indexed chainRegisteredOn, uint256 indexed chainId);

    function initialize(address _owner) external;

    /// @notice Whether the admin of `_chainId` allowed interop with `_peerChainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    function interopPeerAllowed(uint256 _chainId, uint256 _peerChainId) external view returns (bool);

    /// @notice Allows interop between `_chainId` and `_peerChainId` on `_chainId`'s side, on L1 and on
    /// `_chainId`'s L2 Bridgehub. `deregisterInteropPairs` revokes it.
    /// Callable by the admin of `_chainId`. See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain whose admin consents.
    /// @param _peerChainId The chain to allow.
    function allowInteropPeer(uint256 _chainId, uint256 _peerChainId) external;

    /// @notice Removes interop pairs from the L2 Bridgehub of `_chainRegisteredOn`: the pairs registered by the
    /// retired consent-free registration, and allowed pairs, which it also clears on L1. Callable by the owner and by
    /// the admin of `_chainRegisteredOn`. Removing an allowed pair may strand its flows.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainRegisteredOn The chain whose L2 Bridgehub holds the registrations.
    /// @param _chainsToDeregister The registered chains to remove.
    function deregisterInteropPairs(uint256 _chainRegisteredOn, uint256[] calldata _chainsToDeregister) external;
}

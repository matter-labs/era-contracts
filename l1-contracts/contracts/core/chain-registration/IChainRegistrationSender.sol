// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainRegistrationSender {
    /// @notice The admin of `chainId` allowed interop with `peerChainId`.
    event InteropPeerAllowed(uint256 indexed chainId, uint256 indexed peerChainId);

    /// @notice Governance removed `chainId` from the L2 Bridgehub of `chainRegisteredOn`.
    event LegacyPairDeregistered(uint256 indexed chainRegisteredOn, uint256 indexed chainId);

    function initialize(address _owner) external;

    /// @notice Whether the admin of `_chainId` allowed interop with `_peerChainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    function interopPeerAllowed(uint256 _chainId, uint256 _peerChainId) external view returns (bool);

    /// @notice Allows interop between `_chainId` and `_peerChainId` on `_chainId`'s side, on L1 and on
    /// `_chainId`'s L2 Bridgehub. One-way: an allowed pair cannot be revoked.
    /// Callable by the admin of `_chainId`. See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain whose admin consents.
    /// @param _peerChainId The chain to allow.
    function allowInteropPeer(uint256 _chainId, uint256 _peerChainId) external;

    /// @notice Removes pairs registered by the retired consent-free registration from the L2 Bridgehubs.
    /// Cleanup only: allowed pairs cannot be removed. See {protocol-docs/interop-gating.md#governance-procedure}.
    /// @param _chainsRegisteredOn The chains whose L2 Bridgehub holds the registration.
    /// @param _chainsToDeregister The registered chains, one per entry of `_chainsRegisteredOn`.
    function deregisterLegacyPairs(
        uint256[] calldata _chainsRegisteredOn,
        uint256[] calldata _chainsToDeregister
    ) external;
}

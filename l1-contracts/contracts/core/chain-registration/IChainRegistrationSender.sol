// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainRegistrationSender {
    /// @notice The admin of `chainId` allowed or revoked interop with `peerChainId`.
    event InteropPeerSet(uint256 indexed chainId, uint256 indexed peerChainId, bool allowed);

    /// @notice Governance removed `chainId` from the L2 Bridgehub of `chainRegisteredOn`.
    event LegacyPairDeregistered(uint256 indexed chainRegisteredOn, uint256 indexed chainId);

    function initialize(address _owner) external;

    /// @notice Whether the admin of `_chainId` allowed interop with `_peerChainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    function interopPeerAllowed(uint256 _chainId, uint256 _peerChainId) external view returns (bool);

    /// @notice Retired consent-free registration; always reverts. Use `setInteropPeer`.
    function registerChain(uint256 _chainToBeRegistered, uint256 _chainRegisteredOn) external;

    /// @notice Allows or revokes interop between `_chainId` and `_peerChainId` on `_chainId`'s side, and
    /// sends the result to `_chainId`'s L2 Bridgehub. Callable by the admin of `_chainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain whose admin consents.
    /// @param _peerChainId The chain to allow or revoke.
    /// @param _allowed Whether interop with `_peerChainId` is allowed.
    function setInteropPeer(uint256 _chainId, uint256 _peerChainId, bool _allowed) external;

    /// @notice Removes pairs registered by the retired consent-free registration from the L2 Bridgehubs.
    /// See {protocol-docs/interop-gating.md#governance-procedure}.
    /// @param _chainsRegisteredOn The chains whose L2 Bridgehub holds the registration.
    /// @param _chainsToDeregister The registered chains, one per entry of `_chainsRegisteredOn`.
    function deregisterLegacyPairs(
        uint256[] calldata _chainsRegisteredOn,
        uint256[] calldata _chainsToDeregister
    ) external;
}

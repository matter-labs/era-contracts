// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainRegistrationSender {
    /// @notice The admin of `chainId` allowed interop with `peerChainId`.
    event InteropPeerAllowed(uint256 indexed chainId, uint256 indexed peerChainId);

    /// @notice The owner or the admin of `chainRegisteredOn` removed `chainId` from its whitelist.
    event InteropPairDeregistered(uint256 indexed chainRegisteredOn, uint256 indexed chainId);

    /// @notice The owner suspended interop for the chain.
    event InteropSuspended(uint256 indexed chainId);

    /// @notice The owner resumed interop for the chain.
    event InteropResumed(uint256 indexed chainId);

    function initialize(address _owner) external;

    /// @notice Whether the admin of `_chainId` allowed interop with `_peerChainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    function interopPeerAllowed(uint256 _chainId, uint256 _peerChainId) external view returns (bool);

    /// @notice The base token asset id of the chain, snapshotted from the Bridgehub when a chain admin allows it as a
    /// peer; zero until one does. See {protocol-docs/l1sload.md#the-base-token-snapshot}.
    /// @param _chainId The chain to query.
    function interopBaseTokenAssetId(uint256 _chainId) external view returns (bytes32);

    /// @notice Allows interop between `_chainId` and `_peerChainId` on `_chainId`'s side and snapshots the peer's
    /// base token. `deregisterInteropPairs` revokes it. Callable by the admin of `_chainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist} and
    /// {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain whose admin consents.
    /// @param _peerChainId The chain to allow.
    function allowInteropPeer(uint256 _chainId, uint256 _peerChainId) external;

    /// @notice Removes peers from the whitelist of `_chainRegisteredOn`. Callable by the owner and by the admin of
    /// `_chainRegisteredOn`. Removing an allowed pair may strand its flows.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainRegisteredOn The chain whose whitelist is written.
    /// @param _chainsToDeregister The peers to remove.
    function deregisterInteropPairs(uint256 _chainRegisteredOn, uint256[] calldata _chainsToDeregister) external;

    /// @notice Suspends interop for a chain: every chain reading L1 treats it as no peer, in both directions.
    /// Reversible with {resumeInterop}. Callable by the owner.
    /// See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain to suspend.
    function suspendInterop(uint256 _chainId) external;

    /// @notice Lifts a suspension set by {suspendInterop}. Callable by the owner.
    /// @param _chainId The chain to resume.
    function resumeInterop(uint256 _chainId) external;

    /// @notice Whether the owner suspended interop for the chain.
    /// @param _chainId The chain to query.
    function isInteropSuspended(uint256 _chainId) external view returns (bool);
}

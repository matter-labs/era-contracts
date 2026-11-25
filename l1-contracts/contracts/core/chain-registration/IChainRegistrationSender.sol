// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainRegistrationSender {
    /// @notice The admin of `chainId` allowed interop with `peerChainId`.
    event InteropPeerAllowed(uint256 indexed chainId, uint256 indexed peerChainId);

    /// @notice The owner or the admin of `chainRegisteredOn` removed `chainId` from its L2 Bridgehub.
    event InteropPairDeregistered(uint256 indexed chainRegisteredOn, uint256 indexed chainId);

    /// @notice `feature` was enabled or disabled for `chainId`.
    event ChainFeatureSet(uint256 indexed chainId, bytes32 indexed feature, bool enabled);

    /// @notice `writer` may now add `sourceChainId`'s interop roots on `chainId`; zero removes the writer.
    event InteropRootWriterSet(uint256 indexed chainId, uint256 indexed sourceChainId, address indexed writer);

    function initialize(address _owner) external;

    /// @notice Whether the admin of `_chainId` allowed interop with `_peerChainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    function interopPeerAllowed(uint256 _chainId, uint256 _peerChainId) external view returns (bool);

    /// @notice Whether `_feature` is enabled for `_chainId`. See {protocol-docs/interop-gating.md#chain-features}.
    function isChainFeatureEnabled(uint256 _chainId, bytes32 _feature) external view returns (bool);

    /// @notice Enables or disables `_feature` for `_chainId`, on L1 and on the chain's L2 Bridgehub.
    /// Callable by the owner and by the Bridgehub admin, once the chain runs a protocol version whose L2 Bridgehub
    /// has the setter. See {protocol-docs/interop-gating.md#chain-features}.
    /// @param _chainId The chain.
    /// @param _feature The feature id.
    /// @param _enabled Whether the feature is enabled.
    function setChainFeatureEnabled(uint256 _chainId, bytes32 _feature, bool _enabled) external;

    /// @notice The address that may add `_sourceChainId`'s interop roots on `_chainId`, or zero.
    /// See {protocol-docs/interop.md#interop-root-writers}.
    function interopRootWriter(uint256 _chainId, uint256 _sourceChainId) external view returns (address);

    /// @notice Sets the writer of `_sourceChainId`'s interop roots on `_chainId`, on L1 and on the chain's
    /// `L2InteropRootStorage`, once the chain runs protocol version v0.36.0 or later. Setting a writer is callable by
    /// the admin of `_chainId` once the chain feature `INTEROP_ROOT_WRITERS_FEATURE` is enabled for it; removing one
    /// (zero `_writer`) also by the owner and by the Bridgehub admin. A writer can't be set for L1, `_chainId` or a
    /// registered ZK chain; it can still be removed once its source has become a registered ZK chain.
    /// See {protocol-docs/interop.md#interop-root-writers}.
    /// @param _chainId The chain that stores the roots.
    /// @param _sourceChainId The chain whose roots the writer adds.
    /// @param _writer The writer, any address (an operator key or a contract such as a light client), or zero to
    /// remove it.
    function setInteropRootWriter(uint256 _chainId, uint256 _sourceChainId, address _writer) external;

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

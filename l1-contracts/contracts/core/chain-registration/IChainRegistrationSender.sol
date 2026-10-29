// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @notice A protocol feature a chain uses only once the ecosystem admin approved it for the chain and the chain's
/// admin enabled it. See {protocol-docs/interop-gating.md#chain-features}.
enum ChainFeature {
    ExpirableTransfers
}

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IChainRegistrationSender {
    /// @notice The admin of `chainId` allowed interop with `peerChainId`.
    event InteropPeerAllowed(uint256 indexed chainId, uint256 indexed peerChainId);

    /// @notice The owner or the admin of `chainRegisteredOn` removed `chainId` from its L2 Bridgehub.
    event InteropPairDeregistered(uint256 indexed chainRegisteredOn, uint256 indexed chainId);

    /// @notice The ecosystem admin approved or revoked `feature` for `chainId`.
    event ChainFeatureApproved(uint256 indexed chainId, ChainFeature indexed feature, bool approved);

    /// @notice `feature` was enabled or disabled for `chainId`.
    event ChainFeatureEnabled(uint256 indexed chainId, ChainFeature indexed feature, bool enabled);

    function initialize(address _owner) external;

    /// @notice Whether the admin of `_chainId` allowed interop with `_peerChainId`.
    /// See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    function interopPeerAllowed(uint256 _chainId, uint256 _peerChainId) external view returns (bool);

    /// @notice Whether the ecosystem admin approved `_feature` for `_chainId`.
    /// See {protocol-docs/interop-gating.md#chain-features}.
    function isChainFeatureApproved(uint256 _chainId, ChainFeature _feature) external view returns (bool);

    /// @notice Whether `_feature` is enabled for `_chainId`. See {protocol-docs/interop-gating.md#chain-features}.
    function isChainFeatureEnabled(uint256 _chainId, ChainFeature _feature) external view returns (bool);

    /// @notice Approves `_feature` for `_chainId`, or revokes the approval and disables the feature on L1 and on the
    /// chain's L2 Bridgehub. Callable by the owner and by the Bridgehub admin.
    /// See {protocol-docs/interop-gating.md#chain-features}.
    /// @param _chainId The chain.
    /// @param _feature The feature.
    /// @param _approved Whether the chain may enable the feature.
    function setChainFeatureApproved(uint256 _chainId, ChainFeature _feature, bool _approved) external;

    /// @notice Enables or disables an approved `_feature` for `_chainId`, on L1 and on the chain's L2 Bridgehub.
    /// Callable by the admin of `_chainId`. See {protocol-docs/interop-gating.md#chain-features}.
    /// @param _chainId The chain.
    /// @param _feature The feature.
    /// @param _enabled Whether the feature is enabled.
    function setChainFeatureEnabled(uint256 _chainId, ChainFeature _feature, bool _enabled) external;

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

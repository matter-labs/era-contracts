// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IBridgehubBase} from "./IBridgehubBase.sol";
import {InteropCounterparts} from "../../common/Messaging.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Interface for L2-specific Bridgehub functionality
interface IL2Bridgehub is IBridgehubBase {
    /// @notice The interop counterparts of `chainId` were set; zero addresses remove them.
    event InteropCounterpartsSet(uint256 indexed chainId, address interopCenter, address assetRouter);

    /// @notice Set addresses
    // function setAddresses(
    //     address _assetRouter,
    //     ICTMDeploymentTracker _l1CtmDeployer,
    //     IMessageRoot _messageRoot,
    //     address _chainAssetHandler,
    //     address _chainRegistrationSender
    // ) external;

    /// @notice Allows interop with a peer chain once its whitelisting on L1 arrives, see
    /// {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain id of the peer chain.
    /// @param _baseTokenAssetId The base token asset id of the peer chain.
    function allowInteropPeer(uint256 _chainId, bytes32 _baseTokenAssetId) external;

    /// @notice Removes a chain from the chains known for interop, an allowed peer included, once its deregistration
    /// on L1 arrives. See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain id of the chain.
    function deregisterChainForInterop(uint256 _chainId) external;

    /// @notice Whether interop with the chain is allowed, see {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain id of the peer chain.
    function isPeerAllowed(uint256 _chainId) external view returns (bool);

    /// @notice Whether `_feature` is enabled for this chain, as last pushed from L1.
    /// See {protocol-docs/interop-gating.md#chain-features}.
    /// @param _feature The feature id.
    function isChainFeatureEnabled(bytes32 _feature) external view returns (bool);

    /// @notice Records whether `_feature` is enabled for this chain. Called by the L1 `ChainRegistrationSender`.
    /// See {protocol-docs/interop-gating.md#chain-features}.
    /// @param _feature The feature id.
    /// @param _enabled Whether the feature is enabled.
    function setChainFeatureEnabled(bytes32 _feature, bool _enabled) external;

    /// @notice The chain id of the L1 at the base of this chain's ecosystem.
    // solhint-disable-next-line func-name-mixedcase
    function L1_CHAIN_ID() external view returns (uint256);

    /// @notice The interop counterparts of `_chainId`: zero unless this chain exchanges one-way bundles with it.
    /// See {protocol-docs/interop.md#counterpart-addressing}.
    /// @param _chainId The chain id of L1 or of a chain whose roots come from an interop root writer.
    function interopCounterparts(uint256 _chainId) external view returns (InteropCounterparts memory);

    /// @notice Sets or removes (zero addresses) the interop counterparts of `_chainId`. Called by the L1
    /// `ChainRegistrationSender`. See {protocol-docs/interop.md#counterpart-addressing}.
    /// @param _chainId The chain id of L1 or of a chain whose roots come from an interop root writer.
    /// @param _interopCenter The chain's interop center, or zero.
    /// @param _assetRouter The chain's asset router, or zero.
    function setInteropCounterparts(uint256 _chainId, address _interopCenter, address _assetRouter) external;
}

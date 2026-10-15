// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IBridgehubBase} from "./IBridgehubBase.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev Interface for L2-specific Bridgehub functionality
interface IL2Bridgehub is IBridgehubBase {
    /// @notice Set addresses
    // function setAddresses(
    //     address _assetRouter,
    //     ICTMDeploymentTracker _l1CtmDeployer,
    //     IMessageRoot _messageRoot,
    //     address _chainAssetHandler,
    //     address _chainRegistrationSender
    // ) external;

    function registerChainForInterop(uint256 _chainId, bytes32 _baseTokenAssetId) external;

    /// @notice Allows interop with a peer chain once its whitelisting on L1 arrives, see
    /// {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain id of the peer chain.
    /// @param _baseTokenAssetId The base token asset id of the peer chain.
    function allowInteropPeer(uint256 _chainId, bytes32 _baseTokenAssetId) external;

    /// @notice Whether interop with the chain is allowed, see {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain id of the peer chain.
    function isPeerAllowed(uint256 _chainId) external view returns (bool);
}

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

    /// @notice The L1 `ChainRegistrationSender` proxy that interop gating is read from: the unaliased
    /// `chainRegistrationSender`. See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    function l1ChainRegistrationSender() external view returns (address);

    /// @notice Whether this chain accepts interop from the chain (the receive filter), read from L1.
    /// See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain id of the peer chain.
    function isPeerAllowed(uint256 _chainId) external view returns (bool);

    /// @notice Whether this chain may send interop to the chain, and the chain's base token, read from L1.
    /// See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain id of the peer chain.
    /// @return allowed Whether this chain may send to the chain.
    /// @return peerBaseTokenAssetId The chain's base token asset id, zero if the chain is not registered for interop.
    function interopSendTarget(uint256 _chainId) external view returns (bool allowed, bytes32 peerBaseTokenAssetId);

    /// @notice The chain's base token snapshot on L1, zero if it is not registered for interop.
    /// See {protocol-docs/l1sload.md#the-base-token-snapshot}.
    /// @param _chainId The chain id of the chain.
    function interopBaseTokenAssetId(uint256 _chainId) external view returns (bytes32);
}

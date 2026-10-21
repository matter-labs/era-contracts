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

    /// @notice The L1 `ChainRegistrationSender` proxy, whose interop gating state the chain reads with L1SLOAD: the
    /// unaliased `chainRegistrationSender`. See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    function l1ChainRegistrationSender() external view returns (address);

    /// @notice Whether this chain accepts interop from the chain: this chain's admin allowed it on L1 and neither
    /// chain is suspended, read from L1 at the chain's L1SLOAD anchor. The receive filter, see
    /// {protocol-docs/interop-gating.md#receive-filter} and {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain id of the peer chain.
    function isPeerAllowed(uint256 _chainId) external view returns (bool);

    /// @notice Whether this chain may send interop to the chain, and the chain's base token, read from L1 at the
    /// chain's L1SLOAD anchor. Sending needs both admins' consent and neither chain suspended.
    /// See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain id of the peer chain.
    /// @return allowed Whether this chain may send to the chain.
    /// @return peerBaseTokenAssetId The chain's base token asset id, zero if the chain is not registered for interop.
    function interopSendTarget(uint256 _chainId) external view returns (bool allowed, bytes32 peerBaseTokenAssetId);

    /// @notice Whether the chain is registered for interop, i.e. some chain admin allowed it as a peer on L1, which
    /// required it to be in the L1 MessageRoot. Read from L1 at the chain's L1SLOAD anchor.
    /// See {protocol-docs/l1sload.md#the-base-token-snapshot}.
    /// @param _chainId The chain id of the chain.
    function isInteropRegistered(uint256 _chainId) external view returns (bool);
}

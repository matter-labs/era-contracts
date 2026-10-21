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

    /// @notice Allows interop with a peer chain once its whitelisting on L1 arrives, see
    /// {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain id of the peer chain.
    /// @param _baseTokenAssetId The base token asset id of the peer chain.
    function allowInteropPeer(uint256 _chainId, bytes32 _baseTokenAssetId) external;

    /// @notice Removes a chain from the chains known for interop, an allowed peer included, once its deregistration
    /// on L1 arrives. See {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// @param _chainId The chain id of the chain.
    function deregisterChainForInterop(uint256 _chainId) external;

    /// @notice The L1 read addresses were set, see {setL1ReadAddresses}.
    event L1ReadAddressesSet(address l1MessageRoot, address l1ChainRegistrationSender);

    /// @notice Whether interop with the chain is allowed, see {protocol-docs/interop-gating.md#interop-peer-whitelist}.
    /// Once the L1 read addresses are set, it is read from L1, see
    /// {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain id of the peer chain.
    function isPeerAllowed(uint256 _chainId) external view returns (bool);

    /// @notice Whether this chain may send interop to the chain: {isPeerAllowed}, and, once the L1 read addresses
    /// are set, the peer allowed this chain too. See {protocol-docs/l1sload.md#interop-gating-through-l1-reads}.
    /// @param _chainId The chain id of the peer chain.
    function canSendTo(uint256 _chainId) external view returns (bool);

    /// @notice Sets the L1 contracts whose state {isPeerAllowed} and {canSendTo} read with L1SLOAD. Zero addresses
    /// switch back to the mirrored whitelist. Callable by the owner.
    /// @param _l1MessageRoot The L1 `L1MessageRoot` proxy.
    /// @param _l1ChainRegistrationSender The L1 `ChainRegistrationSender` proxy.
    function setL1ReadAddresses(address _l1MessageRoot, address _l1ChainRegistrationSender) external;

    /// @notice The L1 `L1MessageRoot` proxy read with L1SLOAD, or zero.
    function l1MessageRoot() external view returns (address);

    /// @notice The L1 `ChainRegistrationSender` proxy read with L1SLOAD, or zero.
    function l1ChainRegistrationSender() external view returns (address);
}

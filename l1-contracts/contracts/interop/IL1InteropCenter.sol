// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {InteropCallStarter} from "../common/Messaging.sol";

/// @title IL1InteropCenter
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice Sends one-way interop bundles from an L1 to the chains that settle on it.
/// See {protocol-docs/interop.md#one-way-bundles-from-an-l1}.
interface IL1InteropCenter {
    /// @notice Sending bundles to `chainId` was enabled or disabled.
    event DestinationEnabledSet(uint256 indexed chainId, bool enabled);

    /// @notice A bundle was sent to `destinationChainId` as the only message of this chain's batch `batchNumber`
    /// in the message root.
    event OneWayBundleSent(bytes32 indexed bundleHash, uint256 indexed destinationChainId, uint256 batchNumber);

    /// @notice Whether bundles may be sent to `_chainId`.
    function destinationEnabled(uint256 _chainId) external view returns (bool);

    /// @notice Whether `_sender` already used `_salt`; a (sender, salt) pair sends at most one bundle.
    function isInteropBundleSaltUsed(address _sender, bytes32 _salt) external view returns (bool);

    /// @notice Enables or disables sending bundles to `_chainId`. Callable by the owner.
    /// See {protocol-docs/interop-gating.md#one-way-bundles-from-an-l1}.
    /// @param _chainId The destination chain.
    /// @param _enabled Whether bundles may be sent to it.
    function setDestinationEnabled(uint256 _chainId, bool _enabled) external;

    /// @notice Sends a one-way bundle to a chain that settles on this chain: one asset transfer through this
    /// chain's asset router, without value. Same arguments as `IInteropCenter.sendBundle`.
    /// See {protocol-docs/interop.md#one-way-bundles-from-an-l1} for the restrictions.
    /// @param _destinationChainId ERC-7930 address of the destination chain, with an empty address field.
    /// @param _callStarters Exactly one call starter: an indirect call to this chain's asset router.
    /// @param _bundleAttributes At most the `interopBundleSalt` attribute.
    /// @return bundleHash The hash of the sent bundle.
    function sendBundle(
        bytes calldata _destinationChainId,
        InteropCallStarter[] calldata _callStarters,
        bytes[] calldata _bundleAttributes
    ) external returns (bytes32 bundleHash);
}

// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title Proxy upgrade initialization surface.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A row's reinitializer is never calldata — and never data: when a row's
///         `callInitializeUpgrade` is set, `applyRows` invokes exactly `initializeUpgrade()` —
///         fixed selector, no arguments — on the freshly-upgraded proxy, and everything the
///         reinitializer needs lives in the new implementation's own audited code (constants,
///         or immutables on L1 — both pinned by the row's `implNew` codehash). There is no
///         runtime data channel at all: nothing offchain-authored can steer the call, and there
///         is nothing to fetch.
interface IProxyUpgradeInitializable {
    /// @notice Reinitializes the proxy after an implementation swap. Implementations MUST guard
    ///         against replay (a reinitializer version), since this is an external function on
    ///         the proxy.
    function initializeUpgrade() external;
}

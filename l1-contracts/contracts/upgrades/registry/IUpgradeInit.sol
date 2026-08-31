// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title Proxy upgrade initialization surface.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A row's reinitializer is never calldata: when `callInitializeUpgrade` is set,
///         `applyRows` invokes exactly `initializeUpgrade()` — fixed selector, no arguments —
///         on the freshly-upgraded proxy. Whatever the implementation needs is its own audited
///         code's business: constants or immutables (pinned by the row's codehash), or reads
///         from the registry object being applied — `msg.sender` inside the call is the
///         ProxyAdmin, its `owner()` is the executor (or the bootstrap migration), and that
///         owner answers {IActiveRegistryProvider.activeRegistry} with the manifest-committed
///         object governance approved.
interface IProxyUpgradeInitializable {
    /// @notice Reinitializes the proxy after an implementation swap. Implementations MUST guard
    ///         against replay (a reinitializer version), since this is an external function on
    ///         the proxy.
    function initializeUpgrade() external;
}

/// @notice Names the registry object a reinitializing implementation may read during a
///         registry-driven upgrade. Implemented by the executors (nonzero only WHILE rows are
///         being applied — outside an application the call reverts) and by the bootstrap
///         migration (which is itself the manifest object).
interface IActiveRegistryProvider {
    /// @notice The write-once registry object whose rows are currently being applied.
    function activeRegistry() external view returns (address);
}

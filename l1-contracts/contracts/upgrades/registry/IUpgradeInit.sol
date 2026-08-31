// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

/// @title Proxy upgrade initialization surface.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A row's reinitializer is never free-form calldata: `applyRows` invokes exactly
///         `initializeUpgrade()` — fixed selector, no arguments — on the freshly-upgraded proxy
///         when its row carries nonempty `initData`. The implementation fetches that pinned data
///         itself: `msg.sender` inside the call is the ProxyAdmin, its `owner()` is the
///         executor, and the executor serves {IUpgradeInitDataProvider.upgradeInitData} from the
///         registry object it is currently applying — so the data source is the same audited,
///         manifest-committed object governance approved, and the decoding lives in the audited
///         implementation instead of in offchain-authored bytes.
interface IProxyUpgradeInitializable {
    /// @notice Reinitializes the proxy after an implementation swap. Implementations fetch
    ///         their parameters via {IUpgradeInitDataProvider} and MUST guard against replay
    ///         (a reinitializer version), since this is an external function on the proxy.
    function initializeUpgrade() external;
}

/// @notice Serves a proxy's pinned `initData` during a registry-driven upgrade. Implemented by
///         the executors (forwarding to the registry object being applied — outside an
///         application there is no active object and the call reverts) and by the bootstrap
///         migration (serving its own manifest).
interface IUpgradeInitDataProvider {
    /// @notice The pinned reinitialization data for `_proxy`'s row in the active inventory.
    /// @param _proxy The proxy being reinitialized (`address(this)` inside `initializeUpgrade`).
    function upgradeInitData(address _proxy) external view returns (bytes memory);
}

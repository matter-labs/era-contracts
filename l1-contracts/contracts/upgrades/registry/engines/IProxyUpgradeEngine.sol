// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProxyUpgradeContext, ProxyUpgradeRow} from "../RegistryTypes.sol";

/// @title Proxy upgrade engine.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The code a `ProxyUpgradeTransition` pins to apply itself. A domain executor
///         DELEGATECALLS exactly {executeUpgrade} on its transition's `proxyUpgradeEngine`, so the
///         engine acts with the executor's authority: its `ProxyAdmin` and, in the CTM domain, the
///         CTM and the ServerNotifier. That is how an upgrade's follow-up calls (cross-contract
///         wiring after the swaps) become audited Solidity in a reviewed, pinned contract instead
///         of governance calldata. See {DefaultProxyUpgradeEngine}.
/// @dev While delegatecalled every storage slot is the executor's: where a release engine keeps its
///      configuration is in "Follow-up calls: the pinned upgrade engine" in
///      {docs/registry-driven-upgrades.md}. So is the boundary: the executor's post-checks refuse a
///      hook that hands a holder of the domain away or leaves a row off its `implNew`; everything
///      else an engine does through the `ProxyAdmin`, the storage of any proxy under it included,
///      rests on the review of the engine's code.
interface IProxyUpgradeEngine {
    /// @notice Applies a transition: its rows and whatever follow-up work the engine defines.
    /// @param _context Where the engine runs, built by the executor from its own bindings.
    /// @param _inventory The transition's enum-indexed inventory, exactly as pinned.
    function executeUpgrade(ProxyUpgradeContext calldata _context, ProxyUpgradeRow[] calldata _inventory) external;
}

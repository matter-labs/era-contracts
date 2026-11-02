// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProxyUpgradeContext, ProxyUpgradeRow} from "../RegistryTypes.sol";

/// @title Proxy upgrade engine.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The code a `ProxyUpgradeTransition` pins to apply itself. A domain executor
///         DELEGATECALLS exactly {executeUpgrade} on its transition's `upgradeEngine`, so the
///         engine acts with the executor's authority: its `ProxyAdmin` and, in the CTM domain, the
///         CTM and the ServerNotifier. That is how an upgrade's follow-up calls (cross-contract
///         wiring after the swaps) become audited Solidity in a reviewed, pinned contract instead
///         of governance calldata. See {DefaultProxyUpgradeEngine}.
/// @dev An engine is trusted with the executor's storage too: while delegatecalled it MUST NOT read
///      or write storage, since every slot is the executor's. A release engine that needs
///      configuration keeps it in its own storage, written by its constructor, and reads it through
///      an external call to `_context.upgradeEngine`.
interface IProxyUpgradeEngine {
    /// @notice Applies a transition: its rows and whatever follow-up work the engine defines.
    /// @param _context Where the engine runs, built by the executor from its own bindings.
    /// @param _inventory The transition's enum-indexed inventory, exactly as pinned.
    function executeUpgrade(ProxyUpgradeContext calldata _context, ProxyUpgradeRow[] calldata _inventory) external;
}

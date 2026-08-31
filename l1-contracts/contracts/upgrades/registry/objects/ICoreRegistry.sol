// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {ProxyUpgradeRow} from "../RegistryTypes.sol";

/// @title Core (ecosystem-wide) upgrade registry.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a storage-backed, write-once registry that pins every
///         ecosystem-wide L1 contract row for one protocol upgrade, as a `fromState -> toState`
///         edge (see {ProxyUpgradeRow}).
/// @dev The registry is initialized once from an audited manifest; `manifestHash` commits to the
///      pinned values and each `implNew` carries an inline `EXTCODEHASH` pin verified by
///      `validate()` / `verifyAll()`. Version-schedule identity is owned by {ICTMTransition},
///      not pinned here.
interface ICoreRegistry {
    /// @notice `keccak256(abi.encode(manifest))` — the 32-byte commitment to every pinned value:
    ///         the single value governance reviews against the audited manifest.
    function manifestHash() external view returns (bytes32);

    /// @notice Every ecosystem contract participating in this upgrade, as complete typed rows —
    ///         one call, no per-key rescans. Consumers iterate these directly.
    function ecosystemRows() external view returns (ProxyUpgradeRow[] memory);

    /// @notice Walks every pinned implementation and compares its `EXTCODEHASH` against the hash
    ///         pinned at generation time. Anyone can call this to check that deployed bytecode
    ///         matches what was audited. Each registry (core + per-CTM) is verified independently.
    function verifyAll() external view returns (bool);

    /// @notice The reverting counterpart of {verifyAll}, used on execution paths.
    function validate() external view;

    /// @notice The pinned `initData` of the row upgrading `_proxy` — served (through the
    ///         executor) to the new implementation's fixed `initializeUpgrade()`; see
    ///         {IUpgradeInit.sol}. Reverts when no row upgrades `_proxy`.
    function upgradeInitData(address _proxy) external view returns (bytes memory);
}

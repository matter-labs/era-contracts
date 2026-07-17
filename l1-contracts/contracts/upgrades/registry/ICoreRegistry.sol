// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {L1EcosystemContract} from "./ContractIdentifiers.sol";

/// @notice One ecosystem contract's upgrade row: which proxy, and the new-version implementation
///         it must point at afterwards (`implNew == address(0)` means nothing to upgrade).
///         Version-independent proxy + post-upgrade impl; old implementations are not recorded —
///         the upgrade only needs where each proxy points AFTER it runs.
struct EcosystemContractRow {
    L1EcosystemContract key;
    address proxy;
    address implNew;
}

/// @title Core (ecosystem-wide) upgrade registry.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a storage-backed, write-once registry that pins every
///         ecosystem-wide L1 contract row for one protocol upgrade.
/// @dev The registry is initialized once from an audited manifest; `manifestHash` commits to the
///      pinned values and each pinned L1 address carries an `EXTCODEHASH` pin verified by
///      `validate()` / `verifyAll()`. Version-schedule identity is owned by {ICTMTransition}, not
///      pinned here.
interface ICoreRegistry {
    /// @notice Every ecosystem contract participating in this upgrade, as complete typed rows —
    ///         one call, no per-key rescans. Consumers iterate these directly.
    function ecosystemRows() external view returns (EcosystemContractRow[] memory);

    /// @notice The ecosystem `ProxyAdmin` that administers every ecosystem proxy.
    function proxyAdmin() external view returns (address);

    /// @notice Walks every pinned L1 address and compares its `EXTCODEHASH` against the hash
    ///         pinned at generation time. Anyone can call this to check that deployed bytecode
    ///         matches what was audited. Each registry (core + per-CTM) is verified independently.
    function verifyAll() external view returns (bool);

    function validate() external view;
}

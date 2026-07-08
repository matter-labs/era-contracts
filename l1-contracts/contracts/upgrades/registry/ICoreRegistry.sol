// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {EcosystemContract} from "./ContractIdentifiers.sol";

/// @title Core (ecosystem-wide) upgrade registry.
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The lookup surface of a generated, constants-in-bytecode registry that pins every
///         ecosystem-wide L1 contract address for one protocol upgrade (old version -> new version).
/// @dev Implementations hold all values as compile-time constants: every getter is `pure` and the
///      deployed bytecode itself is the commitment to the upgrade manifest (its `EXTCODEHASH`
///      commits to every pinned value). Implementations are generated from the audited manifest,
///      never hand-written, and are redeployed to a new address for every upgrade.
/// @dev Getters revert for unknown `(contract, version)` combinations.
interface ICoreRegistry {
    /// @notice The packed SemVer (see `SemVer.sol`) protocol version this registry upgrades from.
    function oldProtocolVersion() external view returns (uint256);

    /// @notice The packed SemVer protocol version this registry upgrades to.
    function newProtocolVersion() external view returns (uint256);

    /// @notice Proxy address of an ecosystem contract. Version-independent: proxies survive upgrades.
    function proxyAddress(EcosystemContract _contract) external view returns (address);

    /// @notice The new-version implementation address of an ecosystem contract, or zero when this
    ///         upgrade pins no new implementation for it (nothing to upgrade). Old-version
    ///         implementations are deliberately not recorded: the upgrade only needs where each
    ///         proxy must point AFTER it runs.
    /// @param _contract The ecosystem contract identifier; unknown identifiers revert.
    function implAddress(EcosystemContract _contract) external view returns (address);

    /// @notice The ecosystem contracts that participate in this upgrade (i.e. that have a proxy
    ///         and, when upgraded, a new implementation pinned in this registry).
    function ecosystemContractList() external view returns (EcosystemContract[] memory);

    /// @notice The ecosystem `ProxyAdmin` that administers every ecosystem proxy.
    function proxyAdmin() external view returns (address);

    /// @notice The per-CTM registry holding CTM-scoped addresses, facet selector lists,
    ///         L2 bytecode hashes and genesis parameters.
    /// @param _isZKsyncOS False for the Era (EraVM) CTM registry, true for the ZKsyncOS one.
    function ctmRegistry(bool _isZKsyncOS) external view returns (address);

    /// @notice Walks every pinned L1 address (including the CTM registries, recursively) and
    ///         compares its `EXTCODEHASH` against the hash pinned at generation time. Anyone can
    ///         call this to check that deployed bytecode matches what was audited.
    function verifyAll() external view returns (bool);
}

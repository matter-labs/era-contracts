// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";

import {IProxyUpgradeEngine} from "./IProxyUpgradeEngine.sol";
import {ProxyUpgradeRowLib} from "../libraries/ProxyUpgradeRowLib.sol";
import {ProxyUpgradeContext, ProxyUpgradeRow} from "../RegistryTypes.sol";
import {ProxyUpgradeEngineAuthorityMismatch} from "../../../common/L1ContractErrors.sol";

/// @title DefaultProxyUpgradeEngine
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The engine of a transition with no follow-up work: it applies the rows with the
///         source-checked semantics of {ProxyUpgradeRowLib.applyRows} (fixed
///         `initializeUpgrade()` reinitializers included) and nothing else.
/// @dev A release whose upgrade needs follow-up calls INHERITS this contract and overrides the
///      hooks, writing the calls as typed Solidity (`abi.encodeCall`) against targets derived from
///      `_context` or from canonical getters. The rule for every hook, because a transition can be
///      applied again (every row already installed) and the hooks then run again: read the live
///      state first, skip what is already at its target, act on the reviewed source state, and
///      revert on anything else. {executeUpgrade} itself is not virtual, so the order cannot change.
///
///      No state variables and no constructor: this code runs in the executor's storage (see
///      {IProxyUpgradeEngine} for how a subclass keeps configuration).
contract DefaultProxyUpgradeEngine is IProxyUpgradeEngine {
    /// @inheritdoc IProxyUpgradeEngine
    /// @dev Runs only under the authority that owns `_context.proxyAdmin`, i.e. delegatecalled by
    ///      its executor; a direct call has no authority to lend and reverts here.
    function executeUpgrade(ProxyUpgradeContext calldata _context, ProxyUpgradeRow[] calldata _inventory) external {
        ProxyAdmin proxyAdmin = ProxyAdmin(_context.proxyAdmin);
        address proxyAdminOwner = proxyAdmin.owner();
        if (proxyAdminOwner != address(this)) {
            revert ProxyUpgradeEngineAuthorityMismatch(address(proxyAdmin), proxyAdminOwner);
        }
        ProxyUpgradeRow[] memory inventory = _inventory;
        _beforeSwaps(_context, inventory);
        ProxyUpgradeRowLib.applyRows(
            proxyAdmin,
            ProxyUpgradeRowLib.toRows(inventory, ProxyUpgradeRowLib.inventoryLength(_context.domain))
        );
        _afterSwaps(_context, inventory);
        _checkPostconditions(_context, inventory);
    }

    /// @notice Work that must see the departing implementations. Runs before any swap.
    /// @param _context Where the engine runs.
    /// @param _inventory The transition's enum-indexed inventory.
    function _beforeSwaps(ProxyUpgradeContext memory _context, ProxyUpgradeRow[] memory _inventory) internal virtual {}

    /// @notice The follow-up calls: cross-contract wiring once every row runs its `implNew`.
    /// @param _context Where the engine runs.
    /// @param _inventory The transition's enum-indexed inventory.
    function _afterSwaps(ProxyUpgradeContext memory _context, ProxyUpgradeRow[] memory _inventory) internal virtual {}

    /// @notice Reads back what the hooks were meant to establish and reverts unless it holds, so a
    ///         skipped or wrong follow-up fails the leg instead of completing it.
    /// @param _context Where the engine runs.
    /// @param _inventory The transition's enum-indexed inventory.
    function _checkPostconditions(
        ProxyUpgradeContext memory _context,
        ProxyUpgradeRow[] memory _inventory
    ) internal view virtual {}
}

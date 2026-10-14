// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {ObjectAnchorLib} from "./ObjectAnchorLib.sol";
import {IProxyUpgradeInitializable} from "../IUpgradeInit.sol";
import {ProxyUpgradeRow} from "../RegistryTypes.sol";
import {
    ProxyUpgradeRowMismatch,
    RegistryDuplicateProxyRow,
    RegistryInventoryLengthMismatch,
    ZeroAddress
} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice THE `ProxyUpgradeRow` semantics, shared by everything that carries rows (the core
///         transition, the operation's CTM-domain inventory, the bootstrap migration) and
///         everything that applies them: rows are SOURCE-CHECKED edges — a proxy already at
///         `implNew` is skipped (idempotence); a proxy at `expectedOldImpl` is upgraded; a proxy
///         at anything else reverts, so replaying a stale object can never downgrade a proxy that
///         a later upgrade has already moved on.
/// @dev Manifests carry rows as inventories indexed by the canonical contract enums
///      (`L1EcosystemContract` for the ecosystem domain, `CTMContract` for the CTM domain — one
///      enum per domain for deployment and upgrades alike), with the array length checked
///      against the enum's member count. `toRows` is the single point where those become the
///      row arrays everything below consumes, dropping the slots marked "not upgraded" (zero
///      `implNew`). Appliers therefore never see the inventory shape and survive it growing.
library ProxyUpgradeRowLib {
    /// @notice Emitted (from the applying contract) for every proxy pointed at its new
    ///         implementation. The proxy ADDRESS is the row identity (human labels live in the
    ///         off-chain manifest).
    event ProxyImplementationUpgraded(address indexed proxy, address newImpl);

    /// @notice Flattens an enum-indexed inventory into rows. Its length must be exactly the domain
    ///         enum's member count (`L1_ECOSYSTEM_CONTRACT_COUNT` / `CTM_CONTRACT_COUNT` — the
    ///         caller passes its domain's), so every member of the domain HAS a slot and none can
    ///         be smuggled in.
    /// @dev What that does NOT establish is that the slot says what the upgrade meant it to say: an
    ///      inert slot reads the same whether the upgrade leaves the contract alone or whether
    ///      preparation never built its row. Only preparation can tell those apart, and it does —
    ///      see `DefaultCoreUpgrade._requireDeployedImplementationsInstalled`.
    function toRows(
        ProxyUpgradeRow[] memory _slots,
        uint256 _inventoryLength
    ) internal pure returns (ProxyUpgradeRow[] memory) {
        if (_slots.length != _inventoryLength) {
            revert RegistryInventoryLengthMismatch(_inventoryLength, _slots.length);
        }
        return _dropInertSlots(_slots);
    }

    /// @notice Shape discipline shared by every row-carrying manifest: every row is a REAL,
    ///         unique edge — known source, named target, one row per proxy. Placeholder rows
    ///         (zero fields) are refused: a contract not participating in the upgrade is an
    ///         inventory slot `toRows` already dropped, never a row. Code existence is NOT
    ///         checked here (an object may be constructed alongside the implementations it
    ///         names); `requireRowCode` holds that on the execution paths.
    function validateRows(ProxyUpgradeRow[] memory _rows) internal pure {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            ProxyUpgradeRow memory row = _rows[i];
            if (row.proxy == address(0) || row.expectedOldImpl == address(0) || row.implNew == address(0)) {
                revert ZeroAddress();
            }
            for (uint256 j = 0; j < i; ++j) {
                if (_rows[j].proxy == row.proxy) {
                    revert RegistryDuplicateProxyRow(row.proxy);
                }
            }
        }
    }

    /// @notice Reverts unless every row's `implNew` is deployed code.
    function requireRowCode(ProxyUpgradeRow[] memory _rows) internal view {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            ObjectAnchorLib.requireCode(_rows[i].implNew);
        }
    }

    /// @notice Applies every row with the source-checked semantics above through `_admin`, the
    ///         applying contract's bound `ProxyAdmin`, which administers every proxy of its domain,
    ///         then verifies every row's proxy runs its `implNew` before returning.
    /// @dev The verification is a separate pass after every swap, so a reinitializer that moves
    ///      any proxy of the row set is caught too.
    function applyRows(ProxyAdmin _admin, ProxyUpgradeRow[] memory _rows) internal {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(_rows[i].proxy);
            address newImpl = _rows[i].implNew;
            address liveImpl = _admin.getProxyImplementation(proxy);
            if (liveImpl == newImpl) {
                continue;
            }
            if (liveImpl != _rows[i].expectedOldImpl) {
                revert ProxyUpgradeRowMismatch(_rows[i].proxy, _rows[i].expectedOldImpl, liveImpl);
            }
            if (_rows[i].callInitializeUpgrade) {
                // The reinitializer carries no arguments and no data — see {IUpgradeInit.sol}.
                _admin.upgradeAndCall(proxy, newImpl, abi.encodeCall(IProxyUpgradeInitializable.initializeUpgrade, ()));
            } else {
                _admin.upgrade(proxy, newImpl);
            }
            emit ProxyImplementationUpgraded(address(proxy), newImpl);
        }
        for (uint256 i = 0; i < length; ++i) {
            address liveImpl = _admin.getProxyImplementation(ITransparentUpgradeableProxy(_rows[i].proxy));
            if (liveImpl != _rows[i].implNew) {
                revert ProxyUpgradeRowMismatch(_rows[i].proxy, _rows[i].implNew, liveImpl);
            }
        }
    }

    /// @dev A slot participates iff `implNew` is set; anything half-filled that survives
    ///      (e.g. an impl without a proxy) is left for `validateRows` to refuse loudly.
    function _dropInertSlots(ProxyUpgradeRow[] memory _slots) private pure returns (ProxyUpgradeRow[] memory rows) {
        uint256 slotsLength = _slots.length;
        uint256 count = 0;
        for (uint256 i = 0; i < slotsLength; ++i) {
            if (_slots[i].implNew != address(0)) {
                ++count;
            }
        }
        rows = new ProxyUpgradeRow[](count);
        uint256 next = 0;
        for (uint256 i = 0; i < slotsLength; ++i) {
            if (_slots[i].implNew != address(0)) {
                rows[next] = _slots[i];
                ++next;
            }
        }
    }
}

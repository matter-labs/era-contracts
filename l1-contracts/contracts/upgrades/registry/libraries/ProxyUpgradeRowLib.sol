// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CodehashPinLib} from "./CodehashPinLib.sol";
import {CTM_CONTRACT_COUNT, L1_ECOSYSTEM_CONTRACT_COUNT} from "./ContractIdentifiers.sol";
import {ProxyUpgradeRow} from "../RegistryTypes.sol";
import {ProxyUpgradeRowMismatch, RegistryDuplicateProxyRow, ZeroAddress} from "../../../common/L1ContractErrors.sol";

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice THE `ProxyUpgradeRow` semantics, shared by everything that carries rows (the core
///         registry, the CTM transition, the bootstrap migration) and everything that applies
///         them: rows are SOURCE-CHECKED edges — a proxy already at `implNew` is skipped
///         (idempotence); a proxy at `expectedOldImpl` is upgraded; a proxy at anything else
///         reverts, so replaying a stale object can never downgrade a proxy that a later upgrade
///         has already moved on.
/// @dev Manifests carry rows as FIXED-LENGTH inventories indexed by the canonical contract
///      enums (`L1EcosystemContract` for the ecosystem domain, `CTMContract` for the CTM
///      domain — one enum per domain for deployment and upgrades alike); the `toRows`
///      flatteners are the single point where those become the row arrays everything below
///      consumes, dropping the slots explicitly marked "not upgraded" (zero `implNew.addr`).
///      Appliers therefore never see the inventory shape and survive it growing.
library ProxyUpgradeRowLib {
    /// @notice Emitted (from the applying contract) for every proxy pointed at its new
    ///         implementation. The proxy ADDRESS is the row identity (human labels live in the
    ///         off-chain manifest).
    event ProxyImplementationUpgraded(address indexed proxy, address newImpl);

    /// @notice Flattens the ecosystem inventory (indexed by `L1EcosystemContract`) into rows.
    function toRows(
        ProxyUpgradeRow[L1_ECOSYSTEM_CONTRACT_COUNT] memory _slots
    ) internal pure returns (ProxyUpgradeRow[] memory) {
        ProxyUpgradeRow[] memory slots = new ProxyUpgradeRow[](L1_ECOSYSTEM_CONTRACT_COUNT);
        for (uint256 i = 0; i < L1_ECOSYSTEM_CONTRACT_COUNT; ++i) {
            slots[i] = _slots[i];
        }
        return _dropInertSlots(slots);
    }

    /// @notice Flattens the CTM-domain inventory (indexed by `CTMContract`) into rows.
    function toRows(
        ProxyUpgradeRow[CTM_CONTRACT_COUNT] memory _slots
    ) internal pure returns (ProxyUpgradeRow[] memory) {
        ProxyUpgradeRow[] memory slots = new ProxyUpgradeRow[](CTM_CONTRACT_COUNT);
        for (uint256 i = 0; i < CTM_CONTRACT_COUNT; ++i) {
            slots[i] = _slots[i];
        }
        return _dropInertSlots(slots);
    }

    /// @notice Shape discipline shared by every row-carrying manifest: every row is a REAL,
    ///         unique edge — known source, pinned target, one row per proxy. Placeholder rows
    ///         (zero fields) are refused: a contract not participating in the upgrade is an
    ///         inventory slot `toRows` already dropped, never a row. Codehash pins are NOT
    ///         checked here (the manifest supplies both halves of each pair); `requireRowPins`
    ///         holds them against live code on the execution paths.
    function validateRows(ProxyUpgradeRow[] memory _rows) internal pure {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            ProxyUpgradeRow memory row = _rows[i];
            if (row.proxy == address(0) || row.expectedOldImpl == address(0) || row.implNew.addr == address(0)) {
                revert ZeroAddress();
            }
            for (uint256 j = 0; j < i; ++j) {
                if (_rows[j].proxy == row.proxy) {
                    revert RegistryDuplicateProxyRow(row.proxy);
                }
            }
        }
    }

    /// @notice Reverts unless every row's `implNew` pin holds against live code.
    function requireRowPins(ProxyUpgradeRow[] memory _rows) internal view {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            CodehashPinLib.requirePin(_rows[i].implNew);
        }
    }

    /// @notice Non-reverting variant for `verifyAll()` tooling reads.
    function rowPinsHold(ProxyUpgradeRow[] memory _rows) internal view returns (bool) {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            if (!CodehashPinLib.pinHolds(_rows[i].implNew)) {
                return false;
            }
        }
        return true;
    }

    /// @notice Applies every row through `_admin` with the source-checked semantics above.
    function applyRows(ProxyAdmin _admin, ProxyUpgradeRow[] memory _rows) internal {
        uint256 length = _rows.length;
        for (uint256 i = 0; i < length; ++i) {
            address newImpl = _rows[i].implNew.addr;
            ITransparentUpgradeableProxy proxy = ITransparentUpgradeableProxy(_rows[i].proxy);
            address liveImpl = _admin.getProxyImplementation(proxy);
            if (liveImpl == newImpl) {
                continue;
            }
            if (liveImpl != _rows[i].expectedOldImpl) {
                revert ProxyUpgradeRowMismatch(_rows[i].proxy, _rows[i].expectedOldImpl, liveImpl);
            }
            if (_rows[i].initCalldata.length == 0) {
                _admin.upgrade(proxy, newImpl);
            } else {
                _admin.upgradeAndCall(proxy, newImpl, _rows[i].initCalldata);
            }
            emit ProxyImplementationUpgraded(address(proxy), newImpl);
        }
    }

    /// @dev A slot participates iff `implNew.addr` is set; anything half-filled that survives
    ///      (e.g. an impl without a proxy) is left for `validateRows` to refuse loudly.
    function _dropInertSlots(ProxyUpgradeRow[] memory _slots) private pure returns (ProxyUpgradeRow[] memory rows) {
        uint256 slotsLength = _slots.length;
        uint256 count = 0;
        for (uint256 i = 0; i < slotsLength; ++i) {
            if (_slots[i].implNew.addr != address(0)) {
                ++count;
            }
        }
        rows = new ProxyUpgradeRow[](count);
        uint256 next = 0;
        for (uint256 i = 0; i < slotsLength; ++i) {
            if (_slots[i].implNew.addr != address(0)) {
                rows[next] = _slots[i];
                ++next;
            }
        }
    }
}

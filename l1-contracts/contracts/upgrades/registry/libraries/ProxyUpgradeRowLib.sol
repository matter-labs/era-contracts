// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {ProxyAdmin} from "@openzeppelin/contracts-v4/proxy/transparent/ProxyAdmin.sol";
import {ITransparentUpgradeableProxy} from "@openzeppelin/contracts-v4/proxy/transparent/TransparentUpgradeableProxy.sol";

import {CodehashPinLib} from "./CodehashPinLib.sol";
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
library ProxyUpgradeRowLib {
    /// @notice Emitted (from the applying contract) for every proxy pointed at its new
    ///         implementation. The proxy ADDRESS is the row identity (human labels live in the
    ///         off-chain manifest).
    event ProxyImplementationUpgraded(address indexed proxy, address newImpl);

    /// @notice Shape discipline shared by every row-carrying manifest: every row is a REAL,
    ///         unique edge — known source, pinned target, one row per proxy. Placeholder rows
    ///         (zero fields) are refused: a contract not participating in the upgrade simply has
    ///         no row. Codehash pins are NOT checked here (the manifest supplies both halves of
    ///         each pair); `requireRowPins` holds them against live code on the execution paths.
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
            _admin.upgrade(proxy, newImpl);
            emit ProxyImplementationUpgraded(address(proxy), newImpl);
        }
    }
}

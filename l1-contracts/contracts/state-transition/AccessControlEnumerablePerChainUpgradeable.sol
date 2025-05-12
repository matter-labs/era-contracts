// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {Initializable} from "@openzeppelin/contracts-upgradeable-v4/proxy/utils/Initializable.sol";
import {AccessControlEnumerableUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/access/AccessControlEnumerableUpgradeable.sol";

import {RoleAccessDenied, DefaultAdminTransferNotAllowed} from "../common/L1ContractErrors.sol";

/// @title Chain‑Aware Role‑Based Access Control (Enumerable)
/// @notice Drop‑in replacement for the previous `AccessControlEnumerablePerChainUpgradeable` implementation
///         that *reuses* OpenZeppelin's `AccessControlEnumerableUpgradeable` under the hood while exposing
///         exactly the same external interface (explicit `_chainId` argument everywhere).
///
///         A role *key* `R` scoped to a particular chain `C` is materialised as the derived role identifier
///         `keccak256(abi.encodePacked(R, C))` — i.e. `keccak(R, C)`.  All calls into the OZ base contract use
///         this derived identifier; callers continue to supply the original (un‑hashed) role keys.
///
///         As in the original design, the "default admin" for a chain is NOT stored in storage and cannot be
///         transferred.  It must be provided by the inheriting contract via `_getChainAdmin()`.
abstract contract AccessControlEnumerablePerChainUpgradeable is Initializable, AccessControlEnumerableUpgradeable {
    /// ----------------------------
    /// --------- Storage ----------
    /// ----------------------------

    /**
     * @dev Mapping that records, **per chain**, what *role key* acts as admin for another role key.
     *      We must keep it ourselves (rather than rely on OZ) so that we can return *un‑hashed* keys
     *      from {getRoleAdmin}.  Internally we still register the *derived* (hashed) admin with OZ so
     *      that the permissioning logic works.
     *
     *      `_adminRoleKeys[chainId][childRoleKey] = parentAdminRoleKey`  (raw keys, *not* hashed).
     */
    mapping(uint256 => mapping(bytes32 => bytes32)) private _adminRoleKeys;

    /// ----------------------------
    /// ---------- Events ----------
    /// ----------------------------

    /// @notice Emitted when `roleKey` is granted to `account` for a specific `chainId`.
    event RoleGranted(uint256 indexed chainId, bytes32 indexed roleKey, address indexed account);

    /// @notice Emitted when `roleKey` is revoked from `account` for a specific `chainId`.
    event RoleRevoked(uint256 indexed chainId, bytes32 indexed roleKey, address indexed account);

    /// @notice Emitted when the **admin role key** that controls `roleKey` on `chainId` changes.
    event RoleAdminChanged(
        uint256 indexed chainId,
        bytes32 indexed roleKey,
        bytes32 previousAdminRoleKey,
        bytes32 newAdminRoleKey
    );

    /// ----------------------------
    /// -------- Initializer -------
    /// ----------------------------

    constructor() {
        _disableInitializers();
    }

    function __AccessControlEnumerablePerChain_init() internal onlyInitializing {
        __AccessControlEnumerable_init();
    }

    /// ----------------------------
    /// ---------- Helpers ---------
    /// ----------------------------

    /// @dev Deterministically compute the **derived** role identifier for (`roleKey`, `chainId`).
    function _roleForChain(bytes32 roleKey, uint256 chainId) internal pure returns (bytes32) {
        if (roleKey == DEFAULT_ADMIN_ROLE) {
            // keccak(DEFAULT_ADMIN_ROLE, C) is unnecessary – the default admin is handled specially.
            return DEFAULT_ADMIN_ROLE;
        }
        return keccak256(abi.encodePacked(roleKey, chainId));
    }

    /// @dev Internal check that mirrors OpenZeppelin's `_checkRole` but is aware of `_chainId` and the
    ///      implicit chain admin owner for `DEFAULT_ADMIN_ROLE`.
    function _checkRole(uint256 chainId, bytes32 roleKey, address account) internal view {
        if (!hasRole(chainId, roleKey, account)) {
            revert RoleAccessDenied(chainId, roleKey, account);
        }
    }

    /// ----------------------------
    /// -------- Modifiers ---------
    /// ----------------------------

    /// @notice Ensures that `msg.sender` possesses `roleKey` on `chainId`.
    modifier onlyRoleForChainId(uint256 chainId, bytes32 roleKey) {
        _checkRole(chainId, roleKey, msg.sender);
        _;
    }

    /// ----------------------------
    /// ------- View Getters -------
    /// ----------------------------

    /// @notice Returns `true` iff `_account` has `roleKey` on `chainId`.
    function hasRole(uint256 chainId, bytes32 roleKey, address account) public view returns (bool) {
        if (roleKey == DEFAULT_ADMIN_ROLE) {
            return account == _getChainAdmin(chainId);
        }
        return super.hasRole(_roleForChain(roleKey, chainId), account);
    }

    /// @notice Returns the *admin role key* (raw, **not** hashed) that controls `roleKey` on `chainId`.
    function getRoleAdmin(uint256 chainId, bytes32 roleKey) public view returns (bytes32) {
        if (roleKey == DEFAULT_ADMIN_ROLE) {
            return DEFAULT_ADMIN_ROLE;
        }
        bytes32 adminKey = _adminRoleKeys[chainId][roleKey];
        return adminKey == bytes32(0) ? DEFAULT_ADMIN_ROLE : adminKey;
    }

    /// @notice Returns one of the accounts that have `roleKey` on `chainId`.
    function getRoleMember(
        uint256 chainId,
        bytes32 roleKey,
        uint256 index
    ) public view returns (address) {
        return super.getRoleMember(_roleForChain(roleKey, chainId), index);
    }

    /// @notice Returns the number of accounts that possess `roleKey` on `chainId`.
    function getRoleMemberCount(uint256 chainId, bytes32 roleKey) public view returns (uint256) {
        return super.getRoleMemberCount(_roleForChain(roleKey, chainId));
    }

    /// ----------------------------
    /// ------ Role Operations ------
    /// ----------------------------

    /// @notice Grants `roleKey` on `chainId` to `account`.
    function grantRole(
        uint256 chainId,
        bytes32 roleKey,
        address account
    ) public onlyRoleForChainId(chainId, getRoleAdmin(chainId, roleKey)) {
        if (roleKey == DEFAULT_ADMIN_ROLE) revert DefaultAdminTransferNotAllowed();

        if (!hasRole(chainId, roleKey, account)) {
            _grantRole(_roleForChain(roleKey, chainId), account);
            emit RoleGranted(chainId, roleKey, account);
        }
        // Silent no‑op if already held (mirrors OZ semantics).
    }

    /// @notice Revokes `roleKey` on `chainId` from `account`.
    function revokeRole(
        uint256 chainId,
        bytes32 roleKey,
        address account
    ) public onlyRoleForChainId(chainId, getRoleAdmin(chainId, roleKey)) {
        _revokeRoleInternal(chainId, roleKey, account);
    }

    /// @notice Renounces `roleKey` on `chainId` for the calling account.
    function renounceRole(uint256 chainId, bytes32 roleKey) public onlyRoleForChainId(chainId, roleKey) {
        _revokeRoleInternal(chainId, roleKey, msg.sender);
    }

    /// @notice Sets a new *admin role key* for `roleKey` on `chainId`.
    function setRoleAdmin(
        uint256 chainId,
        bytes32 roleKey,
        bytes32 newAdminRoleKey
    ) public onlyRoleForChainId(chainId, getRoleAdmin(chainId, roleKey)) {
        if (roleKey == DEFAULT_ADMIN_ROLE) revert DefaultAdminTransferNotAllowed();

        bytes32 previousAdminKey = getRoleAdmin(chainId, roleKey);
        _adminRoleKeys[chainId][roleKey] = newAdminRoleKey;

        // Reflect the change in the underlying OZ storage as well.
        _setRoleAdmin(
            _roleForChain(roleKey, chainId),
            _roleForChain(newAdminRoleKey, chainId)
        );

        emit RoleAdminChanged(chainId, roleKey, previousAdminKey, newAdminRoleKey);
    }

    /// ----------------------------
    /// ------- Internal ops -------
    /// ----------------------------

    /// @dev Internal implementation of role revocation (no access checks).
    function _revokeRoleInternal(uint256 chainId, bytes32 roleKey, address account) internal {
        if (roleKey == DEFAULT_ADMIN_ROLE) revert DefaultAdminTransferNotAllowed();

        if (hasRole(chainId, roleKey, account)) {
            _revokeRole(_roleForChain(roleKey, chainId), account);
            emit RoleRevoked(chainId, roleKey, account);
        }
        // Silent no‑op if the role was absent (same semantics as OZ).
    }

    /// ----------------------------
    /// ------ Chain Admin hook -----
    /// ----------------------------

    /// @notice Returns the *single holder* of `DEFAULT_ADMIN_ROLE` on `chainId`.
    /// @dev Must be implemented by the inheriting contract.
    function _getChainAdmin(uint256 chainId) internal view virtual returns (address);

    /// ----------------------------
    /// ---- Storage gap (EIP‑7201)
    /// ----------------------------

    uint256[45] private __gap; // 50 ‑ 5 (in OZ) = 45
}

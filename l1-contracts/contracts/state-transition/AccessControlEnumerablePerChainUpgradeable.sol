// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/structs/EnumerableSetUpgradeable.sol";

import {RoleAccessDenied, DefaultAdminTransferNotAllowed} from "../common/L1ContractErrors.sol";

/// @title Chain‑Aware Role‑Based Access Control with Enumeration
/// @notice Similar to OpenZeppelin's `AccessControlEnumerable`, but keeps a completely separate
///         role registry per `chainId`. This is useful for cross‑chain applications where the
///         same contract state is deployed on multiple networks and a distinct set of operators
///         is required on each of them.
/// @dev This contract purposefully does *not* inherit from OZ's `AccessControlUpgradeable` to
///      avoid global (cross‑chain) role collisions. Instead, every public method explicitly
///      takes a `_chainId` argument.
abstract contract AccessControlEnumerablePerChainUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    /// @notice Emitted when `role` is granted to `account` for a specific `chainId`.
    /// @param chainId  The chain identifier on which the role is granted.
    /// @param role     The granted role identifier.
    /// @param account  The account receiving the role.
    event RoleGranted(uint256 indexed chainId, bytes32 indexed role, address indexed account);

    /// @notice Emitted when `role` is revoked from `account` for a specific `chainId`.
    /// @param chainId  The chain identifier on which the role is revoked.
    /// @param role     The revoked role identifier.
    /// @param account  The account losing the role.
    event RoleRevoked(uint256 indexed chainId, bytes32 indexed role, address indexed account);

    /// @notice Emitted when the admin role that controls `role` on `chainId` changes.
    /// @param chainId            The chain identifier on which the admin role is changed.
    /// @param role               The affected role.
    /// @param previousAdminRole  The role that previously had admin privileges.
    /// @param newAdminRole       The new admin role.
    event RoleAdminChanged(
        uint256 indexed chainId,
        bytes32 indexed role,
        bytes32 previousAdminRole,
        bytes32 newAdminRole
    );

    struct RoleData {
        // @dev Although this mapping seems redundant (having the `_roleMembers` mapping),
        // it was left here to preserve the original OZ implementation.
        mapping(address => bool) members;
        bytes32 adminRole; // 0x00 means DEFAULT_ADMIN_ROLE
    }

    /// @notice Mapping that stores roles for each chainId
    mapping(uint256 chainId => mapping(bytes32 role => RoleData)) private _roles;

    /// @dev Mapping that stores EnumerableSet of members for each role for each chainId
    mapping(uint256 chainId => mapping(bytes32 role => EnumerableSetUpgradeable.AddressSet)) private _roleMembers;

    /// @notice The default admin role.
    /// @notice For each chain, the default admin role at any point of time belongs to
    /// and only to the chain admin of the chain, which should be obtained by the `_getChainAdmin` function.
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Ensures that `msg.sender` possesses `_role` on `_chainId`.
    /// @param _chainId The chain identifier.
    /// @param _role    The required role.
    modifier onlyRole(uint256 _chainId, bytes32 _role) {
        _checkRole(_chainId, _role, msg.sender);
        _;
    }

    /// @notice Returns `true` if `_account` holds `_role` for `_chainId`.
    /// @param _chainId The chain identifier.
    /// @param _role    The role identifier.
    /// @param _account The account to check.
    function hasRole(uint256 _chainId, bytes32 _role, address _account) public view returns (bool) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            return _account == _getChainAdmin(_chainId);
        }
        return _roles[_chainId][_role].members[_account];
    }

    /// @notice Returns the admin role that controls `_role` on `_chainId`.
    /// @dev If no admin role was explicitly set, `DEFAULT_ADMIN_ROLE` is returned.
    function getRoleAdmin(uint256 _chainId, bytes32 _role) public view returns (bytes32) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            return DEFAULT_ADMIN_ROLE;
        }
        return _roles[_chainId][_role].adminRole;
    }

    /// @notice Returns one of the accounts that have `_role` on `_chainId`.
    /// @param _chainId The chain identifier.
    /// @param _role    The role identifier.
    /// @param index    A zero‑based index (ordering is not guaranteed).
    /// @dev `index` must be a value between 0 and {getRoleMemberCount}, non-inclusive.
    /// @dev Does not work for `DEFAULT_ADMIN_ROLE` since it is implicitly derived as chain admin.
    function getRoleMember(uint256 _chainId, bytes32 _role, uint256 index) public view returns (address) {
        return _roleMembers[_chainId][_role].at(index);
    }

    /// @notice Returns the number of accounts that have `_role` on `_chainId`.
    /// @dev Does not work for `DEFAULT_ADMIN_ROLE` since it is implicitly derived as chain admin.
    function getRoleMemberCount(uint256 _chainId, bytes32 _role) public view returns (uint256) {
        return _roleMembers[_chainId][_role].length();
    }

    /// @notice Grants `_role` on `_chainId` to `_account`.
    /// @param _chainId The chain identifier.
    /// @param _role    The role to grant.
    /// @param _account The beneficiary account.
    function grantRole(
        uint256 _chainId,
        bytes32 _role,
        address _account
    ) public onlyRole(_chainId, getRoleAdmin(_chainId, _role)) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            revert DefaultAdminTransferNotAllowed();
        }

        if (!hasRole(_chainId, _role, _account)) {
            _roles[_chainId][_role].members[_account] = true;
            // slither-disable-next-line unused-return
            _roleMembers[_chainId][_role].add(_account);
            emit RoleGranted(_chainId, _role, _account);
        }
        // Silent no‑op if the role was already granted (same semantics as OZ implementation).
    }

    /// @notice Revokes `_role` on `_chainId` from `_account`.
    /// @param _chainId The chain identifier.
    /// @param _role    The role to revoke.
    /// @param _account The target account.
    function revokeRole(
        uint256 _chainId,
        bytes32 _role,
        address _account
    ) public onlyRole(_chainId, getRoleAdmin(_chainId, _role)) {
        _revokeRole(_chainId, _role, _account);
    }

    /// @notice Renounces `_role` on `_chainId` for the calling account.
    /// @param _chainId The chain identifier.
    /// @param _role    The role to renounce.
    function renounceRole(uint256 _chainId, bytes32 _role) public onlyRole(_chainId, _role) {
        _revokeRole(_chainId, _role, msg.sender);
    }

    /// @notice Sets a new admin role for `_role` on `_chainId`.
    /// @param _chainId The chain identifier.
    /// @param _role    The role being configured.
    /// @param _adminRole The role that will act as admin for `_role`.
    function setRoleAdmin(
        uint256 _chainId,
        bytes32 _role,
        bytes32 _adminRole
    ) public onlyRole(_chainId, getRoleAdmin(_chainId, _role)) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            revert DefaultAdminTransferNotAllowed();
        }

        bytes32 previousAdmin = getRoleAdmin(_chainId, _role);
        _roles[_chainId][_role].adminRole = _adminRole;
        emit RoleAdminChanged(_chainId, _role, previousAdmin, _adminRole);
    }

    /// @dev Reverts unless `_account` possesses `_role` on `_chainId`.
    function _checkRole(uint256 _chainId, bytes32 _role, address _account) internal view {
        if (!hasRole(_chainId, _role, _account)) {
            revert RoleAccessDenied(_chainId, _role, _account);
        }
    }

    /// @dev Internal implementation of role revocation. Does *not* perform access checks.
    function _revokeRole(uint256 _chainId, bytes32 _role, address _account) internal {
        if (_role == DEFAULT_ADMIN_ROLE) {
            revert DefaultAdminTransferNotAllowed();
        }

        if (hasRole(_chainId, _role, _account)) {
            _roles[_chainId][_role].members[_account] = false;
            // slither-disable-next-line unused-return
            _roleMembers[_chainId][_role].remove(_account);
            emit RoleRevoked(_chainId, _role, _account);
        }
        // Silent no‑op if the role was absent (same semantics as OZ implementation).
    }

    /// @notice Returns the single holder of `DEFAULT_ADMIN_ROLE` on `_chainId`.
    /// @dev Must be implemented by the inheriting contract (e.g. read from storage or a getter).
    function _getChainAdmin(uint256 _chainId) internal view virtual returns (address);

    /// @dev Reserved storage space to allow for layout changes in future upgrades.
    uint256[48] private __gap;
}

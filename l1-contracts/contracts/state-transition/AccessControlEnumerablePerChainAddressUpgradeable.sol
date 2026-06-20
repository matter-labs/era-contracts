// SPDX-License-Identifier: MIT
pragma solidity ^0.8.28;

import {EnumerableSetUpgradeable} from "@openzeppelin/contracts-upgradeable-v4/utils/structs/EnumerableSetUpgradeable.sol";

import {RoleAccessDenied, DefaultAdminTransferNotAllowed} from "../common/L1ContractErrors.sol";

/// @title Chain‑Address‑Aware Role‑Based Access Control with Enumeration
/// @notice It is an adapted version of OpenZeppelin's `AccessControlEnumerable` that keeps a completely separate
/// role registry per `chainAddress` (i.e. in case of ZK Chains it is their DiamondProxy).
/// This is useful for cross‑chain applications where the same contract state is deployed on multiple networks and a distinct set of operators
/// is required on each of them. Using address instead of chain Id allows to save up gas spent on resolving
/// the address of the `DiamondProxy` from the chainId.
/// @dev This contract purposefully does *not* inherit from OZ's `AccessControlUpgradeable` to
/// avoid global (cross‑chain) role collisions. Instead, every public method explicitly
/// takes a `_chainAddress` argument.
/// @dev Note, that the chains are identified, not by chain id, but by their Diamond Proxy address.
abstract contract AccessControlEnumerablePerChainAddressUpgradeable {
    using EnumerableSetUpgradeable for EnumerableSetUpgradeable.AddressSet;

    /// @notice Emitted when `role` is granted to `account` for a specific `chainAddress`.
    /// @param chainAddress The chain address on which the role is granted.
    /// @param role The granted role identifier.
    /// @param account The account receiving the role.
    event RoleGranted(address indexed chainAddress, bytes32 indexed role, address indexed account);

    /// @notice Emitted when `role` is revoked from `account` for a specific `chainAddress`.
    /// @param chainAddress The chain address on which the role is revoked.
    /// @param role The revoked role identifier.
    /// @param account The account losing the role.
    event RoleRevoked(address indexed chainAddress, bytes32 indexed role, address indexed account);

    /// @notice Emitted when the admin role that controls `role` on `chainAddress` changes.
    /// @param chainAddress The chain address on which the admin role is changed.
    /// @param role The affected role.
    /// @param previousAdminRole The role that previously had admin privileges.
    /// @param newAdminRole The new admin role.
    event RoleAdminChanged(
        address indexed chainAddress,
        bytes32 indexed role,
        bytes32 previousAdminRole,
        bytes32 newAdminRole
    );

    /// @notice The struct representing data about each role.
    /// @param members Enumerable set of members for each role.
    /// @param adminRole The role that can grant or revoke rights for the role.
    struct RoleData {
        EnumerableSetUpgradeable.AddressSet members;
        bytes32 adminRole; // 0x00 means DEFAULT_ADMIN_ROLE
    }

    /// @notice Mapping that stores roles for each chainAddress
    mapping(address chainAddress => mapping(bytes32 role => RoleData)) private _roles;

    /// @notice The default admin role.
    /// @notice For each chain, the default admin role at any point of time belongs to
    /// and only to the chain admin of the chain, which should be obtained by the `_getChainAdmin` function.
    bytes32 public constant DEFAULT_ADMIN_ROLE = 0x00;

    /// @notice Ensures that `msg.sender` possesses `_role` on `_chainAddress`.
    /// @param _chainAddress The chain address.
    /// @param _role The required role.
    modifier onlyRole(address _chainAddress, bytes32 _role) {
        _checkRole(_chainAddress, _role, msg.sender);
        _;
    }

    /// @notice Returns `true` if `_account` holds `_role` for `_chainAddress`.
    /// @param _chainAddress The chain address.
    /// @param _role The role identifier.
    /// @param _account The account to check.
    function hasRole(address _chainAddress, bytes32 _role, address _account) public view returns (bool) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            return _account == _getChainAdmin(_chainAddress);
        }
        return _roles[_chainAddress][_role].members.contains(_account);
    }

    /// @notice Returns the admin role that controls `_role` on `_chainAddress`.
    /// @dev If no admin role was explicitly set, `DEFAULT_ADMIN_ROLE` is returned.
    function getRoleAdmin(address _chainAddress, bytes32 _role) public view returns (bytes32) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            return DEFAULT_ADMIN_ROLE;
        }
        return _roles[_chainAddress][_role].adminRole;
    }

    /// @notice Returns one of the accounts that have `_role` on `_chainAddress`.
    /// @param _chainAddress The chain address.
    /// @param _role The role identifier.
    /// @param _index A zero‑based index (ordering is not guaranteed).
    /// @dev `_index` must be a value between 0 and {getRoleMemberCount}, non-inclusive.
    /// @dev Does not work for `DEFAULT_ADMIN_ROLE` since it is implicitly derived as chain admin.
    function getRoleMember(address _chainAddress, bytes32 _role, uint256 _index) public view returns (address) {
        if (_role == DEFAULT_ADMIN_ROLE && _index == 0) {
            return _getChainAdmin(_chainAddress);
        }
        return _roles[_chainAddress][_role].members.at(_index);
    }

    /// @notice Returns the number of accounts that have `_role` on `_chainAddress`.
    /// @dev Does not work for `DEFAULT_ADMIN_ROLE` since it is implicitly derived as chain admin.
    function getRoleMemberCount(address _chainAddress, bytes32 _role) public view returns (uint256) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            return 1;
        }
        return _roles[_chainAddress][_role].members.length();
    }

    /// @notice Grants `_role` on `_chainAddress` to `_account`.
    /// @param _chainAddress The chain address.
    /// @param _role The role to grant.
    /// @param _account The beneficiary account.
    function grantRole(
        address _chainAddress,
        bytes32 _role,
        address _account
    ) public onlyRole(_chainAddress, getRoleAdmin(_chainAddress, _role)) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            revert DefaultAdminTransferNotAllowed();
        }

        if (!hasRole(_chainAddress, _role, _account)) {
            // slither-disable-next-line unused-return
            _roles[_chainAddress][_role].members.add(_account);
            emit RoleGranted(_chainAddress, _role, _account);
        }
        // Silent no‑op if the role was already granted (same semantics as OZ implementation).
    }

    /// @notice Revokes `_role` on `_chainAddress` from `_account`.
    /// @param _chainAddress The chain address.
    /// @param _role The role to revoke.
    /// @param _account The target account.
    function revokeRole(
        address _chainAddress,
        bytes32 _role,
        address _account
    ) public onlyRole(_chainAddress, getRoleAdmin(_chainAddress, _role)) {
        _revokeRole(_chainAddress, _role, _account);
    }

    /// @notice Renounces `_role` on `_chainAddress` for the calling account.
    /// @param _chainAddress The chain address.
    /// @param _role The role to renounce.
    function renounceRole(address _chainAddress, bytes32 _role) public onlyRole(_chainAddress, _role) {
        _revokeRole(_chainAddress, _role, msg.sender);
    }

    /// @notice Sets a new admin role for `_role` on `_chainAddress`.
    /// @param _chainAddress The chain address.
    /// @param _role The role being configured.
    /// @param _adminRole The role that will act as admin for `_role`.
    function setRoleAdmin(
        address _chainAddress,
        bytes32 _role,
        bytes32 _adminRole
    ) public onlyRole(_chainAddress, getRoleAdmin(_chainAddress, _role)) {
        if (_role == DEFAULT_ADMIN_ROLE) {
            revert DefaultAdminTransferNotAllowed();
        }

        bytes32 previousAdminRole = getRoleAdmin(_chainAddress, _role);
        _roles[_chainAddress][_role].adminRole = _adminRole;
        emit RoleAdminChanged(_chainAddress, _role, previousAdminRole, _adminRole);
    }

    /// @dev Reverts unless `_account` possesses `_role` on `_chainAddress`.
    function _checkRole(address _chainAddress, bytes32 _role, address _account) internal view {
        if (!hasRole(_chainAddress, _role, _account)) {
            revert RoleAccessDenied(_chainAddress, _role, _account);
        }
    }

    /// @dev Internal implementation of role revocation. Does *not* perform access checks.
    function _revokeRole(address _chainAddress, bytes32 _role, address _account) internal {
        if (_role == DEFAULT_ADMIN_ROLE) {
            revert DefaultAdminTransferNotAllowed();
        }

        if (hasRole(_chainAddress, _role, _account)) {
            // slither-disable-next-line unused-return
            _roles[_chainAddress][_role].members.remove(_account);
            emit RoleRevoked(_chainAddress, _role, _account);
        }
        // Silent no‑op if the role was absent (same semantics as OZ implementation).
    }

    /// @notice Returns the single holder of `DEFAULT_ADMIN_ROLE` on `_chainAddress`.
    /// @dev Must be implemented by the inheriting contract (e.g. read from storage or a getter).
    function _getChainAdmin(address _chainAddress) internal view virtual returns (address);

    /// @dev Reserved storage space to allow for layout changes in future upgrades.
    uint256[49] private __gap;
}

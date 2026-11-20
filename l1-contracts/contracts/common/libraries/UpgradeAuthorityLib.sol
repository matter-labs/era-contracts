// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {StorageSlot} from "@openzeppelin/contracts-v4/utils/StorageSlot.sol";

import {IOwnable} from "../interfaces/IOwnable.sol";
import {ERC1967_ADMIN_SLOT} from "../Config.sol";
import {Unauthorized} from "../L1ContractErrors.sol";

/// @title UpgradeAuthorityLib
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice The upgrade authority of an L1 contract behind a transparent proxy: the owner of the
///         `ProxyAdmin` in its EIP-1967 admin slot. See
///         {docs/registry-driven-upgrades.md#what-an-engine-can-reach}.
library UpgradeAuthorityLib {
    /// @notice Reverts unless `msg.sender` is `_owner` or the calling proxy's upgrade authority.
    /// @param _owner The calling contract's owner.
    function requireOwnerOrUpgrader(address _owner) internal view {
        if (msg.sender != _owner && !isUpgrader(msg.sender)) {
            revert Unauthorized(msg.sender);
        }
    }

    /// @notice Whether `_caller` owns the `ProxyAdmin` of the calling proxy.
    /// @param _caller The address to check.
    /// @return Whether `_caller` is the calling proxy's upgrade authority.
    /// @dev A codeless admin (none, or an EOA in tests) has no owner, so there is no upgrade authority.
    function isUpgrader(address _caller) internal view returns (bool) {
        address proxyAdmin = StorageSlot.getAddressSlot(ERC1967_ADMIN_SLOT).value;
        if (proxyAdmin.code.length == 0) {
            return false;
        }
        return _caller == IOwnable(proxyAdmin).owner();
    }
}

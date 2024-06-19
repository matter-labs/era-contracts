// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {Errors} from "../libraries/Errors.sol";
import {Auth} from "../auth/Auth.sol";

import {IUpgradeManager} from "../interfaces/IUpgradeManager.sol";

/**
 * @title Upgrade Manager
 * @notice Abstract contract for managing the upgrade process of the account
 * @author https://getclave.io
 */
abstract contract UpgradeManager is IUpgradeManager, Auth {
    // keccak-256 of "eip1967.proxy.implementation" subtracted by 1
    bytes32 private constant _IMPLEMENTATION_SLOT =
        0x360894a13ba1a3210667c828492db98dca3e2076cc3735a920a3ca505d382bbc;

    /// @inheritdoc IUpgradeManager
    function upgradeTo(address newImplementation) external override onlySelf {
        address oldImplementation;
        assembly {
            oldImplementation := and(
                sload(_IMPLEMENTATION_SLOT),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }
        if (oldImplementation == newImplementation) {
            revert Errors.SAME_IMPLEMENTATION();
        }
        assembly {
            sstore(_IMPLEMENTATION_SLOT, newImplementation)
        }

        emit Upgraded(oldImplementation, newImplementation);
    }

    /// @inheritdoc IUpgradeManager
    function implementation() external view override returns (address) {
        address impl;
        assembly {
            impl := and(
                sload(_IMPLEMENTATION_SLOT),
                0xffffffffffffffffffffffffffffffffffffffff
            )
        }

        return impl;
    }
}

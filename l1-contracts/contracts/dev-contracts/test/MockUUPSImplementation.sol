// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";
import {StorageSlot} from "@openzeppelin/contracts-v4/utils/StorageSlot.sol";

/// @notice A mock UUPS-style implementation with `upgradeTo` and a simple `value()` getter.
contract MockUUPSImplementation is ERC1967Upgrade {
    /// @notice Upgrades the implementation address stored in the ERC1967 implementation slot.
    function upgradeTo(address _implementation) external {
        StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = _implementation;
    }

    /// @notice A sample function to verify that the proxy correctly delegates calls to this implementation.
    function value() external pure returns (uint256) {
        return 42;
    }
}

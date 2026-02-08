// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC1967Upgrade} from "@openzeppelin/contracts-v4/proxy/ERC1967/ERC1967Upgrade.sol";
import {StorageSlot} from "@openzeppelin/contracts-v4/utils/StorageSlot.sol";

/// @notice A mock UUPS-style implementation with `upgradeTo` and a simple `value()` getter.
contract MockUUPSImplementation is ERC1967Upgrade {
    function upgradeTo(address _implementation) external {
        StorageSlot.getAddressSlot(_IMPLEMENTATION_SLOT).value = _implementation;
    }

    function value() external pure returns (uint256) {
        return 42;
    }
}

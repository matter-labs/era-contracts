// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {BOOTLOADER_FORMAL_ADDRESS} from "../Constants.sol";
import {Errors} from "../libraries/Errors.sol";

/**
 * @title BootloaderAuth
 * @notice Abstract contract that allows only calls from bootloader
 * @author https://getclave.io
 */
abstract contract BootloaderAuth {
    modifier onlyBootloader() {
        if (msg.sender != BOOTLOADER_FORMAL_ADDRESS) {
            revert Errors.NOT_FROM_BOOTLOADER();
        }
        _;
    }
}

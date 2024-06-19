// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {BootloaderAuth} from "./BootloaderAuth.sol";
import {ModuleAuth} from "./ModuleAuth.sol";
import {SelfAuth} from "./SelfAuth.sol";
import {HookAuth} from "./HookAuth.sol";
import {Errors} from "../libraries/Errors.sol";

/**
 * @title Auth
 * @notice Abstract contract that organizes authentification logic for the contract
 * @author https://getclave.io
 */
abstract contract Auth is BootloaderAuth, SelfAuth, ModuleAuth, HookAuth {
    modifier onlySelfOrModule() {
        if (msg.sender != address(this) && !_isModule(msg.sender)) {
            revert Errors.NOT_FROM_SELF_OR_MODULE();
        }
        _;
    }
}

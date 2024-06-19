// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {Errors} from "../libraries/Errors.sol";

/**
 * @title ModuleAuth
 * @notice Abstract contract that allows only calls from modules
 * @author https://getclave.io
 */
abstract contract ModuleAuth {
    function _isModule(address addr) internal view virtual returns (bool);

    modifier onlyModule() {
        if (!_isModule(msg.sender)) {
            revert Errors.NOT_FROM_MODULE();
        }
        _;
    }
}

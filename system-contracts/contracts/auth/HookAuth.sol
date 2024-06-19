// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {Errors} from "../libraries/Errors.sol";

/**
 * @title HookAuth
 * @notice Abstract contract that allows only calls from hooks
 * @author https://getclave.io
 */
abstract contract HookAuth {
    function _isHook(address addr) internal view virtual returns (bool);

    modifier onlyHook() {
        if (!_isHook(msg.sender)) {
            revert Errors.NOT_FROM_HOOK();
        }
        _;
    }
}

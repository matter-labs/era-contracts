// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

import {Errors} from "../libraries/Errors.sol";

/**
 * @title SelfAuth
 * @notice Abstract contract that allows only calls by the self contract
 * @author https://getclave.io
 */
abstract contract SelfAuth {
    modifier onlySelf() {
        if (msg.sender != address(this)) {
            revert Errors.NOT_FROM_SELF();
        }
        _;
    }
}

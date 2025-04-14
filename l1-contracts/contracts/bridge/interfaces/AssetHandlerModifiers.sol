// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {NonEmptyMsgValue} from "../../common/L1ContractErrors.sol";

abstract contract AssetHandlerModifiers {
    /// @notice Modifier that ensures that a certain value is zero.
    /// @dev This should be used in bridgeBurn-like functions to ensure that users
    /// do not accidentally provide value there.
    modifier requireZeroValue(uint256 _value) {
        if (_value != 0) {
            revert NonEmptyMsgValue();
        }
        _;
    }
}

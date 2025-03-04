// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {UncheckedMath} from "../../common/libraries/UncheckedMath.sol";

contract UncheckedMathTest {
    function uncheckedInc(uint256 _number) external pure returns (uint256) {
        return UncheckedMath.uncheckedInc(_number);
    }

    function uncheckedAdd(uint256 _lhs, uint256 _rhs) external pure returns (uint256) {
        return UncheckedMath.uncheckedAdd(_lhs, _rhs);
    }
}

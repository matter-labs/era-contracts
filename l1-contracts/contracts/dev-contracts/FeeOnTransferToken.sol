// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

import {TestnetERC20Token} from "./TestnetERC20Token.sol";

contract FeeOnTransferToken is TestnetERC20Token {
    // add this to be excluded from coverage report
    function test() internal override {}

    constructor(
        string memory name_,
        string memory symbol_,
        uint8 decimals_
    ) TestnetERC20Token(name_, symbol_, decimals_) {}

    function _transfer(address from, address to, uint256 amount) internal override {
        super._transfer(from, to, amount - 1);
        super._transfer(from, address(1), 1);
    }
}

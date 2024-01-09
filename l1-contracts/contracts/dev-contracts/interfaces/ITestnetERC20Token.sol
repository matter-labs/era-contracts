// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface ITestnetERC20Token {
    function mint(address _to, uint256 _amount) external returns (bool);

    function decimals() external returns (uint8);
}

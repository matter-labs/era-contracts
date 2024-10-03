// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

interface IL2TokenFundExchange {
    event FundExchangeAccount(address indexed account, uint256 amount);

    function fundExchangeAccount(address _from, uint256 _amount) external;
}

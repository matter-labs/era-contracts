// SPDX-License-Identifier: MIT
pragma solidity ^0.8.10;
// import {IWETH} from './IWETH.sol';
// import {IPool} from './IPool.sol';

interface IWrappedTokenGatewayV3 {
    // function WETH() external view returns (IWETH);

    // function POOL() external view returns (IPool);

    function depositETH(address pool, address onBehalfOf, uint16 referralCode) external payable;

    function withdrawETH(address pool, uint256 amount, address onBehalfOf) external;

    function repayETH(address pool, uint256 amount, address onBehalfOf) external payable;

    function borrowETH(address pool, uint256 amount, uint16 referralCode) external;

    function withdrawETHWithPermit(
        address pool,
        uint256 amount,
        address to,
        uint256 deadline,
        uint8 permitV,
        bytes32 permitR,
        bytes32 permitS
    ) external;
}

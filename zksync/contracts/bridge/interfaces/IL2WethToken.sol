// SPDX-License-Identifier: Apache-2.0
pragma solidity ^0.8.0;

interface IL2WethToken {
    // function initialize(
    //     string memory _name,
    //     string memory _symbol,
    //     uint8 _decimals
    // ) external;
    
    function deposit() external payable;

    function withdraw(uint wad) external;

    event Deposit(address indexed dst, uint wad);
    event Withdrawal(address indexed src, uint wad);

    error WETH_ETHTransferFailed();
    error WETH_InvalidTransferRecipient();

    // ERC20
    // function name() external view returns (string memory);

    // function symbol() external view returns (string memory);

    // function decimals() external view returns (uint8);

    function totalSupply() external view returns (uint);

    function balanceOf(address guy) external view returns (uint);

    function allowance(address src, address dst) external view returns (uint);

    function approve(address spender, uint wad) external returns (bool);

    function transfer(address dst, uint wad) external returns (bool);

    function transferFrom(
        address src,
        address dst,
        uint wad
    ) external returns (bool);

    event Approval(address indexed src, address indexed dst, uint wad);
    event Transfer(address indexed src, address indexed dst, uint wad);
}

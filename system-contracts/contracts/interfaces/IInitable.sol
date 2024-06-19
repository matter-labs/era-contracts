// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.17;

interface IInitable {
    event Inited(address indexed account);
    event Disabled(address indexed account);

    function init(bytes calldata initData) external;

    function disable() external;
}

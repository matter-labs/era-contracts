// SPDX-License-Identifier: MIT

pragma solidity ^0.8.0;

/// @author Matter Labs
interface IL2WethBridge {
    function initialize(
        address _l1Bridge,
        address _l1WethAddress,
        address _governor
    ) external;

    event FinalizeDeposit(
        address indexed l1Sender,
        address indexed l2Receiver,
        address indexed l2Weth,
        uint256 amount
    );

    event WithdrawalInitiated(
        address indexed l2Sender,
        address indexed l1Receiver,
        address indexed l2Weth,
        uint256 amount
    );

    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        uint256 _amount
    ) external payable;

    function withdraw(
        address _l1Receiver,
        uint256 _amount
    ) external;

    function l1WethAddress() external view returns (address);

    function l2WethAddress() external view returns (address);

    function l1WethBridge() external view returns (address);
}

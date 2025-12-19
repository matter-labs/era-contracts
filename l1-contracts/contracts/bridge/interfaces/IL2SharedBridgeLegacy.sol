// SPDX-License-Identifier: MIT

pragma solidity ^0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2SharedBridgeLegacy {
    event FinalizeDeposit(
        address indexed l1Sender,
        address indexed l2Receiver,
        address indexed l2Token,
        uint256 amount
    );

    event WithdrawalInitiated(
        address indexed l2Sender,
        address indexed l1Receiver,
        address indexed l2Token,
        uint256 amount
    );

    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external;

    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external;

    function l1TokenAddress(address _l2Token) external view returns (address);

    function l2TokenAddress(address _l1Token) external view returns (address);

    function deployBeaconProxy(bytes32 _salt) external returns (address);

    function sendMessageToL1(bytes calldata _message) external returns (bytes32);
}

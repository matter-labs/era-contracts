// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @author Matter Labs
interface IL2SharedBridge {
    event FinalizeDeposit(address indexed l1Sender, address indexed l2Token, bytes32 assetDataHash);

    event WithdrawalInitiated(
        address indexed l2Sender,
        address indexed l1Receiver,
        address indexed l2Token,
        bytes32 assetDataHash
    );

    function finalizeDeposit(address _l1Sender, address _l1Token, bytes calldata _data) external;

    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external;

    function l1TokenAddress(address _l2Token) external view returns (address);

    function l2TokenAddress(address _l1Token) external view returns (address);

    function l1Bridge() external view returns (address);
}

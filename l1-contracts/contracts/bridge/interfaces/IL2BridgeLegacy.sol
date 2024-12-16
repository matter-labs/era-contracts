// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL2BridgeLegacy {
    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external;

    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external payable;

    function l1TokenAddress(address _l2Token) external view returns (address);

    function l2TokenAddress(address _l1Token) external view returns (address);
}

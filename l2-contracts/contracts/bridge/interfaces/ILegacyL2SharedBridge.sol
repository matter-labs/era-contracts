// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface ILegacyL2SharedBridge {
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external;

    function withdraw(address _l1Receiver, address _l2Token, uint256 _amount) external;

    function l2TokenAddress(address _l1Token) external view returns (address);
}

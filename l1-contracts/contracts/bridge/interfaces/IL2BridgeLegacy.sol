// SPDX-License-Identifier: MIT

pragma solidity 0.8.24;

/// @author Matter Labs
interface IL2BridgeLegacy {
    function finalizeDeposit(
        address _l1Sender,
        address _l2Receiver,
        address _l1Token,
        uint256 _amount,
        bytes calldata _data
    ) external payable;
}

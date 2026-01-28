// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786Recipient
/// @notice Interface for the ERC7786 recipient
/// https://github.com/ethereum/ERCs/blob/d565ee1faf753abf416a746b15586161e78f2c95/ERCS/erc-7786.md
interface IERC7786Recipient {
    function receiveMessage(
        bytes32 receiveId, // Unique identifier
        bytes calldata sender, // ERC-7930 address
        bytes calldata payload
    ) external payable returns (bytes4);
}

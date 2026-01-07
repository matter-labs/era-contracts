// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786Recipient
/// @notice Interface for the ERC7786 recipient
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
interface IERC7786Recipient {
    function receiveMessage(
        bytes32 receiveId, // Unique identifier
        bytes calldata sender, // ERC-7930 address
        bytes calldata payload
    ) external payable returns (bytes4);
}

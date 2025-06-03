// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786Receiver
/// @notice Interface for the ERC7786 receiver
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
interface IERC7786Receiver {
    function executeMessage(
        // kl todo: change back to strings
        bytes32 messageId, // gateway specific, empty or unique
        uint256 sourceChain, // [CAIP-2] chain identifier
        address sender, // [CAIP-10] account address
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable returns (bytes4);
}

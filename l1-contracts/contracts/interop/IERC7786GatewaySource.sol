// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786GatewaySource
/// @notice Interface for the ERC7786 gateway source
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
interface IERC7786GatewaySource {
    event MessageSent(
        bytes32 indexed sendId,
        bytes sender, // ERC-7930 address
        bytes recipient, // ERC-7930 address
        bytes payload,
        uint256 value,
        bytes[] attributes
    );

    error UnsupportedAttribute(bytes4 selector);

    function supportsAttribute(bytes4 selector) external view returns (bool);

    function sendMessage(
        bytes calldata recipient, // ERC-7930 address
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable returns (bytes32 sendId);
}

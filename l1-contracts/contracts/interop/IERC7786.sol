// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

/// @title IERC7786GatewaySource
/// @notice Interface for the ERC7786 gateway source
/// https://github.com/ethereum/ERCs/blob/023a7d657666308568d3d1391c578d5972636093/ERCS/erc-7786.md
interface IERC7786GatewaySource {
    event MessagePosted(
        bytes32 indexed outboxId,
        string sender,
        string receiver,
        bytes payload,
        uint256 value,
        bytes[] attributes
    );

    error UnsupportedAttribute(bytes4 selector);

    function supportsAttribute(bytes4 selector) external view returns (bool);

    function sendMessage(
        string calldata destinationChain, // [CAIP-2] chain identifier
        string calldata receiver, // [CAIP-10] account address
        bytes calldata payload,
        bytes[] calldata attributes
    ) external payable returns (bytes32 outboxId);

    /// kl todo decide how to merge this and sendMessage, i.e. CAIP. Also put value in an attribute.
    function sendCall(
        uint256 destinationChain,
        address destinationAddress,
        bytes calldata data,
        bytes[] calldata attributes
    ) external payable returns (bytes32 outboxId);

    function quoteRelay(
        string calldata destinationChain,
        string calldata receiver,
        bytes calldata payload,
        bytes[] calldata attributes,
        uint256 gasLimit,
        string[] calldata refundReceivers
    ) external returns (uint256);

    function requestRelay(bytes32 outboxId, uint256 gasLimit, string[] calldata refundReceivers) external payable;
}

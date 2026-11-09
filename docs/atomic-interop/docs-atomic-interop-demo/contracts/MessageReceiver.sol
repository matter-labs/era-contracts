// SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

/// @notice ERC-7786 recipient interface. The interop handler calls it on the destination chain.
interface IERC7786Recipient {
    function receiveMessage(
        bytes32 receiveId,
        bytes calldata sender,
        bytes calldata payload
    ) external payable returns (bytes4);
}

/// @notice Stores the last cross-chain message it received.
contract MessageReceiver is IERC7786Recipient {
    /// @notice The interop handler. Same address on every ZKsync OS chain.
    address public constant INTEROP_HANDLER = 0x000000000000000000000000000000000001000E;

    uint256 public lastSourceChainId;
    address public lastSender;
    string public lastMessage;
    uint256 public lastValue;

    event MessageReceived(
        bytes32 indexed receiveId,
        uint256 sourceChainId,
        address sender,
        string message,
        uint256 value
    );

    error NotInteropHandler(address caller);
    error NotAnErc7930EvmAddress();

    function receiveMessage(
        bytes32 receiveId,
        bytes calldata sender,
        bytes calldata payload
    ) external payable returns (bytes4) {
        // Cross-chain calls arrive from the interop handler.
        if (msg.sender != INTEROP_HANDLER) revert NotInteropHandler(msg.sender);

        // `sender` is the source chain and the account that sent the call (ERC-7930).
        // A real app would check both against an allowlist here.
        (uint256 sourceChainId, address from) = _parseEvmAddress(sender);

        lastSourceChainId = sourceChainId;
        lastSender = from;
        lastMessage = abi.decode(payload, (string));
        lastValue = msg.value;
        emit MessageReceived({
            receiveId: receiveId,
            sourceChainId: sourceChainId,
            sender: from,
            message: lastMessage,
            value: msg.value
        });

        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @dev ERC-7930 EVM address: 0x0001 | 0x0000 | chain ref length | chain ref | 0x14 | address.
    function _parseEvmAddress(bytes calldata s) internal pure returns (uint256 chainId, address addr) {
        if (s.length < 6 || bytes4(s[0:4]) != 0x00010000) revert NotAnErc7930EvmAddress();
        uint256 refLen = uint8(s[4]);
        if (refLen == 0 || refLen > 32 || s.length != 26 + refLen || uint8(s[5 + refLen]) != 20) {
            revert NotAnErc7930EvmAddress();
        }
        chainId = uint256(bytes32(s[5:5 + refLen])) >> (256 - 8 * refLen);
        addr = address(bytes20(s[6 + refLen:26 + refLen]));
    }
}

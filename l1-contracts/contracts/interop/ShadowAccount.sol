// SPDX-License-Identifier: MIT

pragma solidity ^0.8.24;

import {InteroperableAddress} from "../vendor/draft-InteroperableAddress.sol";
import {IERC7786Recipient} from "./IERC7786Recipient.sol";

/// @dev Type of call a ShadowAccount can make on behalf of its owner.
enum ShadowAccountCallType {
    Call,
    DelegateCall
}

/// @dev A single call to execute through a ShadowAccount.
/// @param callType Whether to use CALL or DELEGATECALL.
/// @param target The address to call.
/// @param value The ETH value to send (only for Call type).
/// @param data The calldata payload.
struct ShadowAccountCall {
    ShadowAccountCallType callType;
    address target;
    uint256 value;
    bytes data;
}

/// @title ShadowAccount
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @dev A Smart Account deployed on a remote chain via interop, giving a user
/// access management and contract interaction capabilities on that chain without
/// the user directly deploying an account or having an EOA there.
///
/// Implements ERC-7786 receiveMessage so the InteropHandler delivers messages to it
/// the same way as any other recipient. The payload contains an array of ShadowAccountCall
/// structs — fully generic, supporting both CALL and DELEGATECALL. This lets the sender
/// encode arbitrary multi-step logic (forwarding tokens, sending new bundles, interacting
/// with protocols via delegatecall to script contracts, etc.).
///
/// Deployed deterministically by the InteropHandler via CREATE2.
contract ShadowAccount is IERC7786Recipient {
    /// @notice The InteropHandler address that deployed this shadow account.
    address public immutable INTEROP_HANDLER;

    /// @notice The full ERC-7930 interoperable address of the owner (packed bytes format).
    bytes public fullOwnerAddress;

    /// @notice The chain ID of the owner.
    uint256 public ownerChainId;

    /// @notice The EVM address of the owner on the source chain.
    address public ownerAddress;

    error OnlyInteropHandler(address caller);
    error SenderNotOwner(bytes sender, bytes owner);
    error ShadowAccountCallFailed(uint256 callIndex, bytes returndata);

    /// @notice Creates a new ShadowAccount for the given interoperable owner address.
    /// @param _fullOwnerAddress The ERC-7930 formatted interoperable address of the owner.
    constructor(bytes memory _fullOwnerAddress) {
        INTEROP_HANDLER = msg.sender;
        fullOwnerAddress = _fullOwnerAddress;

        (uint256 chainId, address addr) = InteroperableAddress.parseEvmV1(_fullOwnerAddress);
        ownerChainId = chainId;
        ownerAddress = addr;
    }

    /// @notice Receives a message from the InteropHandler and executes the encoded calls.
    /// @dev The payload must be ABI-encoded as ShadowAccountCall[].
    /// Authorization:
    ///   1. msg.sender must be the InteropHandler — ensures the call comes from a verified interop bundle.
    ///   2. _sender must match the stored owner — ensures only the owner on the home chain controls this account.
    /// @param _sender ERC-7930 address of the message sender (must match owner).
    /// @param _payload ABI-encoded array of ShadowAccountCall structs.
    /// @return The IERC7786Recipient.receiveMessage selector.
    function receiveMessage(
        bytes32 /* _receiveId */,
        bytes calldata _sender,
        bytes calldata _payload
    ) external payable override returns (bytes4) {
        if (msg.sender != INTEROP_HANDLER) {
            revert OnlyInteropHandler(msg.sender);
        }
        if (keccak256(_sender) != keccak256(fullOwnerAddress)) {
            revert SenderNotOwner(_sender, fullOwnerAddress);
        }

        ShadowAccountCall[] memory calls = abi.decode(_payload, (ShadowAccountCall[]));
        uint256 callsLength = calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            bool success;
            bytes memory returndata;
            if (calls[i].callType == ShadowAccountCallType.DelegateCall) {
                // solhint-disable-next-line avoid-low-level-calls
                (success, returndata) = calls[i].target.delegatecall(calls[i].data);
            } else {
                // solhint-disable-next-line avoid-low-level-calls
                (success, returndata) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            }
            if (!success) {
                revert ShadowAccountCallFailed(i, returndata);
            }
        }
        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice Allows the shadow account to receive native tokens.
    receive() external payable {}
}

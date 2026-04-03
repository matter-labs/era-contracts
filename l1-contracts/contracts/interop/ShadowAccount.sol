// SPDX-License-Identifier: MIT

pragma solidity 0.8.28;

import {IERC7786Recipient} from "./IERC7786Recipient.sol";
import {IShadowAccount, ShadowAccountCall, ShadowAccountCallType} from "./IShadowAccount.sol";
import {L2_INTEROP_HANDLER_ADDR, L2_SHADOW_ACCOUNT_FACTORY_ADDR} from "../common/l2-helpers/L2ContractAddresses.sol";
import {ShadowAccountAlreadyInitialized, ShadowAccountCallFailed, ShadowAccountOnlyFactory, ShadowAccountOnlyInteropHandler, ShadowAccountOnlyOwner} from "./InteropErrors.sol";

/// @title ShadowAccount
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
/// @notice A smart account deployed on a remote chain via interop, giving a user contract interaction
///         capabilities on that chain without deploying a smart account or having an EOA there.
/// @dev Implements ERC-7786 `receiveMessage` so that the InteropHandler can deliver messages to it.
///      The message payload is decoded as an array of `ShadowAccountCall` structs which are then
///      executed sequentially. Authorization is two-layered:
///        1. `msg.sender` must be the InteropHandler (ensures call comes from a verified interop bundle).
///        2. The ERC-7786 `_sender` must match the stored `owner` (ensures only the home-chain owner controls this account).
/// @dev No constructor or immutables — L2 contracts in zksync OS do not support them.
contract ShadowAccount is IShadowAccount {
    /// @notice ERC-7930 encoded address of the owner on the home chain.
    bytes public override owner;

    /// @notice Whether the account has been initialized.
    bool private _initialized;

    /// @inheritdoc IShadowAccount
    function initialize(bytes calldata _owner) external {
        require(!_initialized, ShadowAccountAlreadyInitialized());
        require(msg.sender == L2_SHADOW_ACCOUNT_FACTORY_ADDR, ShadowAccountOnlyFactory());
        _initialized = true;
        owner = _owner;
        emit ShadowAccountInitialized(_owner);
    }

    /// @notice Receives an interop message and executes the encoded calls.
    /// @dev Authorization: msg.sender must be InteropHandler AND _sender must match owner.
    /// @param _sender ERC-7930 encoded address of the message sender (must match owner).
    /// @param _payload ABI-encoded array of ShadowAccountCall structs.
    /// @return The `receiveMessage` selector as per ERC-7786.
    function receiveMessage(
        bytes32 /* _receiveId */,
        bytes calldata _sender,
        bytes calldata _payload
    ) external payable override returns (bytes4) {
        require(msg.sender == L2_INTEROP_HANDLER_ADDR, ShadowAccountOnlyInteropHandler());
        require(keccak256(_sender) == keccak256(owner), ShadowAccountOnlyOwner());

        ShadowAccountCall[] memory calls = abi.decode(_payload, (ShadowAccountCall[]));
        uint256 callsLength = calls.length;
        for (uint256 i = 0; i < callsLength; ++i) {
            bool success;
            if (calls[i].callType == ShadowAccountCallType.DelegateCall) {
                // slither-disable-next-line controlled-delegatecall
                (success, ) = calls[i].target.delegatecall(calls[i].data);
            } else {
                // slither-disable-next-line arbitrary-send-eth
                (success, ) = calls[i].target.call{value: calls[i].value}(calls[i].data);
            }
            require(success, ShadowAccountCallFailed(i));
            emit ShadowAccountCallExecuted(i, calls[i].callType, calls[i].target);
        }

        return IERC7786Recipient.receiveMessage.selector;
    }

    /// @notice Allow the shadow account to receive ETH (e.g., from interop value transfers).
    receive() external payable {}
}

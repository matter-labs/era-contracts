// SPDX-License-Identifier: MIT
// We use a floating point pragma here so it can be used within other projects that interact with the ZKsync ecosystem without using our exact pragma version.
pragma solidity ^0.8.21;

import {IndirectCallRequest} from "../../common/Messaging.sol";

/// @title L1 Bridge contract interface
/// @author Matter Labs
/// @custom:security-contact security@matterlabs.dev
interface IL1CrossChainSender {
    /// @notice Builds an indirect priority request for the authorized L1 Interop Center.
    /// @param _chainId Destination chain ID.
    /// @param _originalCaller The `msg.sender` address from the external call that initiated current one.
    /// @param _value The `msg.value` to be deposited on the target chain.
    /// @param _data The indirect call payload.
    /// @return request The data used by the bridgehub to create L2 transaction request to specific ZK chain.
    function initiateIndirectCall(
        uint256 _chainId,
        address _originalCaller,
        uint256 _value,
        bytes calldata _data
    ) external payable returns (IndirectCallRequest memory request);

    /// @notice Routes the confirmation to nullifier for backward compatibility.
    /// @notice Records the canonical hash after the Mailbox accepts the indirect request.
    /// Only the registered L1 Interop Center may confirm a request.
    /// @param _chainId The chain ID of the ZK chain to which confirm the deposit.
    /// @param _txDataHash The keccak256 hash of 0x01 || abi.encode(bytes32, bytes) to identify deposits.
    /// @param _txHash The hash of the L1->L2 transaction to confirm the deposit.
    function confirmL2Transaction(uint256 _chainId, bytes32 _txDataHash, bytes32 _txHash) external;
}

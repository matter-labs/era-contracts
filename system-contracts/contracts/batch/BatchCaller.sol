// SPDX-License-Identifier: MIT
pragma solidity ^0.8.17;

import {SystemContractHelper} from "../libraries/SystemContractHelper.sol";
import {EfficientCall} from "../libraries/EfficientCall.sol";
import {Errors} from "../libraries/Errors.sol";

// Each call data for batches
struct Call {
    address target; // Target contract address
    bool allowFailure; // Whether to revert if the call fails
    uint256 value; // Amount of ETH to send with call
    bytes callData; // Calldata to send
}

/// @title BatchCaller
/// @notice Make multiple calls in a single transaction
contract BatchCaller {
    /// @notice Make multiple calls, ensure success if required
    /// @dev Reverts if not called via delegatecall
    /// @param calls Call[] calldata - An array of Call structs
    function batchCall(Call[] calldata calls) external {
        bool isDelegateCall = SystemContractHelper.getCodeAddress() !=
            address(this);
        if (!isDelegateCall) {
            revert Errors.ONLY_DELEGATECALL();
        }

        // Execute each call
        uint256 len = calls.length;
        Call calldata calli;
        for (uint256 i = 0; i < len; ) {
            calli = calls[i];
            address target = calli.target;
            uint256 value = calli.value;
            bytes calldata callData = calli.callData;

            bool success = EfficientCall.rawCall(
                gasleft(),
                target,
                value,
                callData,
                false
            );
            if (!calls[i].allowFailure && !success) {
                revert Errors.CALL_FAILED();
            }

            unchecked {
                i++;
            }
        }
    }
}

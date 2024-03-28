// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {MSG_VALUE_SYSTEM_CONTRACT} from "./L2ContractHelper.sol";

address constant SYSTEM_CALL_CALL_ADDRESS = address((1 << 16) - 11);
/// @dev If the bitwise AND of the extraAbi[2] param when calling the MSG_VALUE_SIMULATOR
/// is non-zero, the call will be assumed to be a system one.
uint256 constant MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT = 1;

/// @notice The way to forward the calldata:
/// - Use the current heap (i.e. the same as on EVM).
/// - Use the auxiliary heap.
/// - Forward via a pointer
/// @dev Note, that currently, users do not have access to the auxiliary
/// heap and so the only type of forwarding that will be used by the users
/// are UseHeap and ForwardFatPointer for forwarding a slice of the current calldata
/// to the next call.
enum CalldataForwardingMode {
    UseHeap,
    ForwardFatPointer,
    UseAuxHeap
}

library Utils {
    function safeCastToU32(uint256 _x) internal pure returns (uint32) {
        require(_x <= type(uint32).max, "Overflow");

        return uint32(_x);
    }
}

/// @notice The library contains the functions to make system calls.
/// @dev A more detailed description of the library and its methods can be found in the `system-contracts` repo.
library SystemContractsCaller {
    function systemCall(uint32 gasLimit, address to, uint256 value, bytes memory data) internal returns (bool success) {
        address callAddr = SYSTEM_CALL_CALL_ADDRESS;

        uint32 dataStart;
        assembly {
            dataStart := add(data, 0x20)
        }
        uint32 dataLength = uint32(Utils.safeCastToU32(data.length));

        uint256 farCallAbi = getFarCallABI({
            dataOffset: 0,
            memoryPage: 0,
            dataStart: dataStart,
            dataLength: dataLength,
            gasPassed: gasLimit,
            // Only rollup is supported for now
            shardId: 0,
            forwardingMode: CalldataForwardingMode.UseHeap,
            isConstructorCall: false,
            isSystemCall: true
        });

        if (value == 0) {
            // Doing the system call directly
            assembly {
                success := call(to, callAddr, 0, 0, farCallAbi, 0, 0)
            }
        } else {
            address msgValueSimulator = MSG_VALUE_SYSTEM_CONTRACT;
            // We need to supply the mask to the MsgValueSimulator to denote
            // that the call should be a system one.
            uint256 forwardMask = MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT;

            assembly {
                success := call(msgValueSimulator, callAddr, value, to, farCallAbi, forwardMask, 0)
            }
        }
    }

    function systemCallWithReturndata(
        uint32 gasLimit,
        address to,
        uint128 value,
        bytes memory data
    ) internal returns (bool success, bytes memory returnData) {
        success = systemCall(gasLimit, to, value, data);

        uint256 size;
        assembly {
            size := returndatasize()
        }

        returnData = new bytes(size);
        assembly {
            returndatacopy(add(returnData, 0x20), 0, size)
        }
    }

    function getFarCallABI(
        uint32 dataOffset,
        uint32 memoryPage,
        uint32 dataStart,
        uint32 dataLength,
        uint32 gasPassed,
        uint8 shardId,
        CalldataForwardingMode forwardingMode,
        bool isConstructorCall,
        bool isSystemCall
    ) internal pure returns (uint256 farCallAbi) {
        // Fill in the call parameter fields
        farCallAbi = getFarCallABIWithEmptyFatPointer({
            gasPassed: gasPassed,
            shardId: shardId,
            forwardingMode: forwardingMode,
            isConstructorCall: isConstructorCall,
            isSystemCall: isSystemCall
        });
        // Fill in the fat pointer fields
        farCallAbi |= dataOffset;
        farCallAbi |= (uint256(memoryPage) << 32);
        farCallAbi |= (uint256(dataStart) << 64);
        farCallAbi |= (uint256(dataLength) << 96);
    }

    function getFarCallABIWithEmptyFatPointer(
        uint32 gasPassed,
        uint8 shardId,
        CalldataForwardingMode forwardingMode,
        bool isConstructorCall,
        bool isSystemCall
    ) internal pure returns (uint256 farCallAbiWithEmptyFatPtr) {
        farCallAbiWithEmptyFatPtr |= (uint256(gasPassed) << 192);
        farCallAbiWithEmptyFatPtr |= (uint256(forwardingMode) << 224);
        farCallAbiWithEmptyFatPtr |= (uint256(shardId) << 232);
        if (isConstructorCall) {
            farCallAbiWithEmptyFatPtr |= (1 << 240);
        }
        if (isSystemCall) {
            farCallAbiWithEmptyFatPtr |= (1 << 248);
        }
    }
}

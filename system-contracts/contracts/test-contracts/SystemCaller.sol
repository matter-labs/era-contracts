// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {SYSTEM_CALL_CALL_ADDRESS, MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT, SystemContractsCaller, CalldataForwardingMode} from "../libraries/SystemContractsCaller.sol";
import {Utils} from "../libraries/Utils.sol";

address constant REAL_MSG_VALUE_SYSTEM_CONTRACT = address(0x8009);

// Proxy that sets system call, does the same thing as `ExtraAbiCaller.zasm`, but can be called with callee abi, which is more convenient.
// Also updates the real balance of the callee.
contract SystemCaller {
    address immutable to;

    constructor(address _to) {
        to = _to;
    }

    // The library method will not work, because it uses the MsgValueSimulator test address.
    fallback() external payable {
        address callAddr = SYSTEM_CALL_CALL_ADDRESS;

        address _to = to;
        bytes memory data = msg.data;
        uint32 dataStart;
        assembly {
            dataStart := add(data, 0x20)
        }
        uint32 dataLength = uint32(Utils.safeCastToU32(data.length));

        uint256 farCallAbi = SystemContractsCaller.getFarCallABI({
            dataOffset: 0,
            memoryPage: 0,
            dataStart: dataStart,
            dataLength: dataLength,
            gasPassed: Utils.safeCastToU32(gasleft()),
            // Only rollup is supported for now
            shardId: 0,
            forwardingMode: CalldataForwardingMode.UseHeap,
            isConstructorCall: false,
            isSystemCall: true
        });

        bool success;
        if (msg.value == 0) {
            // Doing the system call directly
            assembly {
                success := call(_to, callAddr, 0, 0, farCallAbi, 0, 0)
            }
        } else {
            address msgValueSimulator = REAL_MSG_VALUE_SYSTEM_CONTRACT;
            // We need to supply the mask to the MsgValueSimulator to denote
            // that the call should be a system one.
            uint256 forwardMask = MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT;

            assembly {
                success := call(msgValueSimulator, callAddr, callvalue(), _to, farCallAbi, forwardMask, 0)
            }
        }
        uint256 returnDataSize;
        assembly {
            returnDataSize := returndatasize()
        }
        bytes memory returnData = new bytes(returnDataSize);
        assembly {
            returndatacopy(add(returnData, 0x20), 0, returnDataSize)
            switch success
            case 0 {
                revert(add(returnData, 0x20), returnDataSize)
            }
            default {
                return(add(returnData, 0x20), returnDataSize)
            }
        }
    }
}

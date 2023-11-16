// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {MAX_SYSTEM_CONTRACT_ADDRESS, MSG_VALUE_SYSTEM_CONTRACT} from "../Constants.sol";

import "../libraries/SystemContractsCaller.sol";
import "../libraries/SystemContractHelper.sol";
import "../libraries/Utils.sol";

library TestSystemContractHelper {
    /// @notice Perform a `mimicCall` with `isSystem` flag, with the ability to pass extra abi data.
    /// @param to The address to call
    /// @param whoToMimic The `msg.sender` for the next call.
    /// @param data The calldata
    /// @param isConstructor Whether the call should contain the `isConstructor` flag.
    /// @param extraAbiParam1 The first extraAbi param to pass with the call
    /// @param extraAbiParam2 The second extraAbi param to pass with the call
    /// @return The returndata if the call was successful. Reverts otherwise.
    /// @dev If called not in kernel mode, it will result in a revert (enforced by the VM)
    function systemMimicCall(
        address to,
        address whoToMimic,
        bytes calldata data,
        bool isConstructor,
        uint256 extraAbiParam1,
        uint256 extraAbiParam2
    ) internal returns (bytes memory) {
        bool success = rawSystemMimicCall(to, whoToMimic, data, isConstructor, extraAbiParam1, extraAbiParam2);

        uint256 size;
        assembly {
            size := returndatasize()
        }
        if (!success) {
            assembly {
                returndatacopy(0, 0, size)
                revert(0, size)
            }
        }

        bytes memory result = new bytes(size);
        assembly {
            mstore(result, size)
            returndatacopy(add(result, 0x20), 0, size)
        }
        return result;
    }

    /// @notice Perform a `mimicCall` with `isSystem` flag, with the ability to pass extra abi data.
    /// @param to The address to call
    /// @param whoToMimic The `msg.sender` for the next call.
    /// @param data The calldata
    /// @param isConstructor Whether the call should contain the `isConstructor` flag.
    /// @param extraAbiParam1 The first extraAbi param to pass with the call
    /// @param extraAbiParam2 The second extraAbi param to pass with the call
    /// @return success whether the call was successful.
    /// @dev If called not in kernel mode, it will result in a revert (enforced by the VM)
    function rawSystemMimicCall(
        address to,
        address whoToMimic,
        bytes calldata data,
        bool isConstructor,
        uint256 extraAbiParam1,
        uint256 extraAbiParam2
    ) internal returns (bool success) {
        SystemContractHelper.loadCalldataIntoActivePtr();

        // Currently, zkEVM considers the pointer valid if(ptr.offset < ptr.length || (ptr.length == 0 && ptr.offset == 0)), otherwise panics.
        // So, if the data is empty we need to make the `ptr.length = ptr.offset = 0`, otherwise follow standard logic.
        if (data.length == 0) {
            // Safe to cast, offset is never bigger than `type(uint32).max`
            SystemContractHelper.ptrShrinkIntoActive(uint32(msg.data.length));
        } else {
            uint256 dataOffset;
            assembly {
                dataOffset := data.offset
            }

            // Safe to cast, offset is never bigger than `type(uint32).max`
            SystemContractHelper.ptrAddIntoActive(uint32(dataOffset));
            // Safe to cast, `data.length` is never bigger than `type(uint32).max`
            uint32 shrinkTo = uint32(msg.data.length - (data.length + dataOffset));
            SystemContractHelper.ptrShrinkIntoActive(shrinkTo);
        }

        uint32 gas = Utils.safeCastToU32(gasleft());
        uint256 farCallAbi = SystemContractsCaller.getFarCallABIWithEmptyFatPointer(
            gas,
            // Only rollup is supported for now
            0,
            CalldataForwardingMode.ForwardFatPointer,
            isConstructor,
            true
        );
        SystemContractHelper.ptrPackIntoActivePtr(farCallAbi);

        address callAddr = SYSTEM_MIMIC_CALL_BY_REF_CALL_ADDRESS;
        uint256 cleanupMask = ADDRESS_MASK;
        assembly {
            // Clearing values before usage in assembly, since Solidity
            // doesn't do it by default
            whoToMimic := and(whoToMimic, cleanupMask)

            success := call(to, callAddr, 0, 0, whoToMimic, extraAbiParam1, extraAbiParam2)
        }
    }
}

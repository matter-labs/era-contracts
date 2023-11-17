// SPDX-License-Identifier: MIT

pragma solidity 0.8.20;

import {MAX_SYSTEM_CONTRACT_ADDRESS} from "../Constants.sol";

import {SystemContractsCaller, CalldataForwardingMode, CALLFLAGS_CALL_ADDRESS, CODE_ADDRESS_CALL_ADDRESS, EVENT_WRITE_ADDRESS, EVENT_INITIALIZE_ADDRESS, GET_EXTRA_ABI_DATA_ADDRESS, LOAD_CALLDATA_INTO_ACTIVE_PTR_CALL_ADDRESS, META_CODE_SHARD_ID_OFFSET, META_CALLER_SHARD_ID_OFFSET, META_SHARD_ID_OFFSET, META_AUX_HEAP_SIZE_OFFSET, META_HEAP_SIZE_OFFSET, META_GAS_PER_PUBDATA_BYTE_OFFSET, MIMIC_CALL_BY_REF_CALL_ADDRESS, META_CALL_ADDRESS, MSG_VALUE_SIMULATOR_IS_SYSTEM_BIT, PTR_CALLDATA_CALL_ADDRESS, PTR_ADD_INTO_ACTIVE_CALL_ADDRESS, PTR_SHRINK_INTO_ACTIVE_CALL_ADDRESS, PTR_PACK_INTO_ACTIVE_CALL_ADDRESS, RAW_FAR_CALL_BY_REF_CALL_ADDRESS, PRECOMPILE_CALL_ADDRESS, SET_CONTEXT_VALUE_CALL_ADDRESS, SYSTEM_CALL_BY_REF_CALL_ADDRESS, TO_L1_CALL_ADDRESS} from "./SystemContractsCaller.sol";

uint256 constant UINT32_MASK = 0xffffffff;
uint256 constant UINT128_MASK = 0xffffffffffffffffffffffffffffffff;
/// @dev The mask that is used to convert any uint256 to a proper address.
/// It needs to be padded with `00` to be treated as uint256 by Solidity
uint256 constant ADDRESS_MASK = 0x00ffffffffffffffffffffffffffffffffffffffff;

struct ZkSyncMeta {
    uint32 gasPerPubdataByte;
    uint32 heapSize;
    uint32 auxHeapSize;
    uint8 shardId;
    uint8 callerShardId;
    uint8 codeShardId;
}

enum Global {
    CalldataPtr,
    CallFlags,
    ExtraABIData1,
    ExtraABIData2,
    ReturndataPtr
}

/**
 * @author Matter Labs
 * @custom:security-contact security@matterlabs.dev
 * @notice Library used for accessing zkEVM-specific opcodes, needed for the development
 * of system contracts.
 * @dev While this library will be eventually available to public, some of the provided
 * methods won't work for non-system contracts. We will not recommend this library
 * for external use.
 */
library SystemContractHelper {
    /// @notice Send an L2Log to L1.
    /// @param _isService The `isService` flag.
    /// @param _key The `key` part of the L2Log.
    /// @param _value The `value` part of the L2Log.
    /// @dev The meaning of all these parameters is context-dependent, but they
    /// have no intrinsic meaning per se.
    function toL1(bool _isService, bytes32 _key, bytes32 _value) internal {
        address callAddr = TO_L1_CALL_ADDRESS;
        assembly {
            // Ensuring that the type is bool
            _isService := and(_isService, 1)
            // This `success` is always 0, but the method always succeeds
            // (except for the cases when there is not enough gas)
            let success := call(_isService, callAddr, _key, _value, 0xFFFF, 0, 0)
        }
    }

    /// @notice Get address of the currently executed code.
    /// @dev This allows differentiating between `call` and `delegatecall`.
    /// During the former `this` and `codeAddress` are the same, while
    /// during the latter they are not.
    function getCodeAddress() internal view returns (address addr) {
        address callAddr = CODE_ADDRESS_CALL_ADDRESS;
        assembly {
            addr := staticcall(0, callAddr, 0, 0xFFFF, 0, 0)
        }
    }

    /// @notice Provide a compiler hint, by placing calldata fat pointer into virtual `ACTIVE_PTR`,
    /// that can be manipulated by `ptr.add`/`ptr.sub`/`ptr.pack`/`ptr.shrink` later.
    /// @dev This allows making a call by forwarding calldata pointer to the child call.
    /// It is a much more efficient way to forward calldata, than standard EVM bytes copying.
    function loadCalldataIntoActivePtr() internal view {
        address callAddr = LOAD_CALLDATA_INTO_ACTIVE_PTR_CALL_ADDRESS;
        assembly {
            pop(staticcall(0, callAddr, 0, 0xFFFF, 0, 0))
        }
    }

    /// @notice Compiler simulation of the `ptr.pack` opcode for the virtual `ACTIVE_PTR` pointer.
    /// @dev Do the concatenation between lowest part of `ACTIVE_PTR` and highest part of `_farCallAbi`
    /// forming packed fat pointer for a far call or ret ABI when necessary.
    /// Note: Panics if the lowest 128 bits of `_farCallAbi` are not zeroes.
    function ptrPackIntoActivePtr(uint256 _farCallAbi) internal view {
        address callAddr = PTR_PACK_INTO_ACTIVE_CALL_ADDRESS;
        assembly {
            pop(staticcall(_farCallAbi, callAddr, 0, 0xFFFF, 0, 0))
        }
    }

    /// @notice Compiler simulation of the `ptr.add` opcode for the virtual `ACTIVE_PTR` pointer.
    /// @dev Transforms `ACTIVE_PTR.offset` into `ACTIVE_PTR.offset + u32(_value)`. If overflow happens then it panics.
    function ptrAddIntoActive(uint32 _value) internal view {
        address callAddr = PTR_ADD_INTO_ACTIVE_CALL_ADDRESS;
        uint256 cleanupMask = UINT32_MASK;
        assembly {
            // Clearing input params as they are not cleaned by Solidity by default
            _value := and(_value, cleanupMask)
            pop(staticcall(_value, callAddr, 0, 0xFFFF, 0, 0))
        }
    }

    /// @notice Compiler simulation of the `ptr.shrink` opcode for the virtual `ACTIVE_PTR` pointer.
    /// @dev Transforms `ACTIVE_PTR.length` into `ACTIVE_PTR.length - u32(_shrink)`. If underflow happens then it panics.
    function ptrShrinkIntoActive(uint32 _shrink) internal view {
        address callAddr = PTR_SHRINK_INTO_ACTIVE_CALL_ADDRESS;
        uint256 cleanupMask = UINT32_MASK;
        assembly {
            // Clearing input params as they are not cleaned by Solidity by default
            _shrink := and(_shrink, cleanupMask)
            pop(staticcall(_shrink, callAddr, 0, 0xFFFF, 0, 0))
        }
    }

    /// @notice packs precompile parameters into one word
    /// @param _inputMemoryOffset The memory offset in 32-byte words for the input data for calling the precompile.
    /// @param _inputMemoryLength The length of the input data in words.
    /// @param _outputMemoryOffset The memory offset in 32-byte words for the output data.
    /// @param _outputMemoryLength The length of the output data in words.
    /// @param _perPrecompileInterpreted The constant, the meaning of which is defined separately for
    /// each precompile. For information, please read the documentation of the precompilecall log in
    /// the VM.
    function packPrecompileParams(
        uint32 _inputMemoryOffset,
        uint32 _inputMemoryLength,
        uint32 _outputMemoryOffset,
        uint32 _outputMemoryLength,
        uint64 _perPrecompileInterpreted
    ) internal pure returns (uint256 rawParams) {
        rawParams = _inputMemoryOffset;
        rawParams |= uint256(_inputMemoryLength) << 32;
        rawParams |= uint256(_outputMemoryOffset) << 64;
        rawParams |= uint256(_outputMemoryLength) << 96;
        rawParams |= uint256(_perPrecompileInterpreted) << 192;
    }

    /// @notice Call precompile with given parameters.
    /// @param _rawParams The packed precompile params. They can be retrieved by
    /// the `packPrecompileParams` method.
    /// @param _gasToBurn The number of gas to burn during this call.
    /// @return success Whether the call was successful.
    /// @dev The list of currently available precompiles sha256, keccak256, ecrecover.
    /// NOTE: The precompile type depends on `this` which calls precompile, which means that only
    /// system contracts corresponding to the list of precompiles above can do `precompileCall`.
    /// @dev If used not in the `sha256`, `keccak256` or `ecrecover` contracts, it will just burn the gas provided.
    /// @dev This method is `unsafe` because it does not check whether there is enough gas to burn.
    function unsafePrecompileCall(uint256 _rawParams, uint32 _gasToBurn) internal view returns (bool success) {
        address callAddr = PRECOMPILE_CALL_ADDRESS;

        uint256 cleanupMask = UINT32_MASK;
        assembly {
            // Clearing input params as they are not cleaned by Solidity by default
            _gasToBurn := and(_gasToBurn, cleanupMask)
            success := staticcall(_rawParams, callAddr, _gasToBurn, 0xFFFF, 0, 0)
        }
    }

    /// @notice Set `msg.value` to next far call.
    /// @param _value The msg.value that will be used for the *next* call.
    /// @dev If called not in kernel mode, it will result in a revert (enforced by the VM)
    function setValueForNextFarCall(uint128 _value) internal returns (bool success) {
        uint256 cleanupMask = UINT128_MASK;
        address callAddr = SET_CONTEXT_VALUE_CALL_ADDRESS;
        assembly {
            // Clearing input params as they are not cleaned by Solidity by default
            _value := and(_value, cleanupMask)
            success := call(0, callAddr, _value, 0, 0xFFFF, 0, 0)
        }
    }

    /// @notice Initialize a new event.
    /// @param initializer The event initializing value.
    /// @param value1 The first topic or data chunk.
    function eventInitialize(uint256 initializer, uint256 value1) internal {
        address callAddr = EVENT_INITIALIZE_ADDRESS;
        assembly {
            pop(call(initializer, callAddr, value1, 0, 0xFFFF, 0, 0))
        }
    }

    /// @notice Continue writing the previously initialized event.
    /// @param value1 The first topic or data chunk.
    /// @param value2 The second topic or data chunk.
    function eventWrite(uint256 value1, uint256 value2) internal {
        address callAddr = EVENT_WRITE_ADDRESS;
        assembly {
            pop(call(value1, callAddr, value2, 0, 0xFFFF, 0, 0))
        }
    }

    /// @notice Get the packed representation of the `ZkSyncMeta` from the current context.
    /// @return meta The packed representation of the ZkSyncMeta.
    /// @dev The fields in ZkSyncMeta are NOT tightly packed, i.e. there is a special rule on how
    /// they are packed. For more information, please read the documentation on ZkSyncMeta.
    function getZkSyncMetaBytes() internal view returns (uint256 meta) {
        address callAddr = META_CALL_ADDRESS;
        assembly {
            meta := staticcall(0, callAddr, 0, 0xFFFF, 0, 0)
        }
    }

    /// @notice Returns the bits [offset..offset+size-1] of the meta.
    /// @param meta Packed representation of the ZkSyncMeta.
    /// @param offset The offset of the bits.
    /// @param size The size of the extracted number in bits.
    /// @return result The extracted number.
    function extractNumberFromMeta(uint256 meta, uint256 offset, uint256 size) internal pure returns (uint256 result) {
        // Firstly, we delete all the bits after the field
        uint256 shifted = (meta << (256 - size - offset));
        // Then we shift everything back
        result = (shifted >> (256 - size));
    }

    /// @notice Given the packed representation of `ZkSyncMeta`, retrieves the number of gas
    /// that a single byte sent to L1 as pubdata costs.
    /// @param meta Packed representation of the ZkSyncMeta.
    /// @return gasPerPubdataByte The current price in gas per pubdata byte.
    function getGasPerPubdataByteFromMeta(uint256 meta) internal pure returns (uint32 gasPerPubdataByte) {
        gasPerPubdataByte = uint32(extractNumberFromMeta(meta, META_GAS_PER_PUBDATA_BYTE_OFFSET, 32));
    }

    /// @notice Given the packed representation of `ZkSyncMeta`, retrieves the number of the current size
    /// of the heap in bytes.
    /// @param meta Packed representation of the ZkSyncMeta.
    /// @return heapSize The size of the memory in bytes byte.
    /// @dev The following expression: getHeapSizeFromMeta(getZkSyncMetaBytes()) is
    /// equivalent to the MSIZE in Solidity.
    function getHeapSizeFromMeta(uint256 meta) internal pure returns (uint32 heapSize) {
        heapSize = uint32(extractNumberFromMeta(meta, META_HEAP_SIZE_OFFSET, 32));
    }

    /// @notice Given the packed representation of `ZkSyncMeta`, retrieves the number of the current size
    /// of the auxilary heap in bytes.
    /// @param meta Packed representation of the ZkSyncMeta.
    /// @return auxHeapSize The size of the auxilary memory in bytes byte.
    /// @dev You can read more on auxilary memory in the VM1.2 documentation.
    function getAuxHeapSizeFromMeta(uint256 meta) internal pure returns (uint32 auxHeapSize) {
        auxHeapSize = uint32(extractNumberFromMeta(meta, META_AUX_HEAP_SIZE_OFFSET, 32));
    }

    /// @notice Given the packed representation of `ZkSyncMeta`, retrieves the shardId of `this`.
    /// @param meta Packed representation of the ZkSyncMeta.
    /// @return shardId The shardId of `this`.
    /// @dev Currently only shard 0 (zkRollup) is supported.
    function getShardIdFromMeta(uint256 meta) internal pure returns (uint8 shardId) {
        shardId = uint8(extractNumberFromMeta(meta, META_SHARD_ID_OFFSET, 8));
    }

    /// @notice Given the packed representation of `ZkSyncMeta`, retrieves the shardId of
    /// the msg.sender.
    /// @param meta Packed representation of the ZkSyncMeta.
    /// @return callerShardId The shardId of the msg.sender.
    /// @dev Currently only shard 0 (zkRollup) is supported.
    function getCallerShardIdFromMeta(uint256 meta) internal pure returns (uint8 callerShardId) {
        callerShardId = uint8(extractNumberFromMeta(meta, META_CALLER_SHARD_ID_OFFSET, 8));
    }

    /// @notice Given the packed representation of `ZkSyncMeta`, retrieves the shardId of
    /// the currently executed code.
    /// @param meta Packed representation of the ZkSyncMeta.
    /// @return codeShardId The shardId of the currently executed code.
    /// @dev Currently only shard 0 (zkRollup) is supported.
    function getCodeShardIdFromMeta(uint256 meta) internal pure returns (uint8 codeShardId) {
        codeShardId = uint8(extractNumberFromMeta(meta, META_CODE_SHARD_ID_OFFSET, 8));
    }

    /// @notice Retrieves the ZkSyncMeta structure.
    /// @return meta The ZkSyncMeta execution context parameters.
    function getZkSyncMeta() internal view returns (ZkSyncMeta memory meta) {
        uint256 metaPacked = getZkSyncMetaBytes();
        meta.gasPerPubdataByte = getGasPerPubdataByteFromMeta(metaPacked);
        meta.heapSize = getHeapSizeFromMeta(metaPacked);
        meta.auxHeapSize = getAuxHeapSizeFromMeta(metaPacked);
        meta.shardId = getShardIdFromMeta(metaPacked);
        meta.callerShardId = getCallerShardIdFromMeta(metaPacked);
        meta.codeShardId = getCodeShardIdFromMeta(metaPacked);
    }

    /// @notice Returns the call flags for the current call.
    /// @return callFlags The bitmask of the callflags.
    /// @dev Call flags is the value of the first register
    /// at the start of the call.
    /// @dev The zero bit of the callFlags indicates whether the call is
    /// a constructor call. The first bit of the callFlags indicates whether
    /// the call is a system one.
    function getCallFlags() internal view returns (uint256 callFlags) {
        address callAddr = CALLFLAGS_CALL_ADDRESS;
        assembly {
            callFlags := staticcall(0, callAddr, 0, 0xFFFF, 0, 0)
        }
    }

    /// @notice Returns the current calldata pointer.
    /// @return ptr The current calldata pointer.
    /// @dev NOTE: This file is just an integer and it cannot be used
    /// to forward the calldata to the next calls in any way.
    function getCalldataPtr() internal view returns (uint256 ptr) {
        address callAddr = PTR_CALLDATA_CALL_ADDRESS;
        assembly {
            ptr := staticcall(0, callAddr, 0, 0xFFFF, 0, 0)
        }
    }

    /// @notice Returns the N-th extraAbiParam for the current call.
    /// @return extraAbiData The value of the N-th extraAbiParam for this call.
    /// @dev It is equal to the value of the (N+2)-th register
    /// at the start of the call.
    function getExtraAbiData(uint256 index) internal view returns (uint256 extraAbiData) {
        require(index < 10, "There are only 10 accessible registers");

        address callAddr = GET_EXTRA_ABI_DATA_ADDRESS;
        assembly {
            extraAbiData := staticcall(index, callAddr, 0, 0xFFFF, 0, 0)
        }
    }

    /// @notice Retuns whether the current call is a system call.
    /// @return `true` or `false` based on whether the current call is a system call.
    function isSystemCall() internal view returns (bool) {
        uint256 callFlags = getCallFlags();
        // When the system call is passed, the 2-bit it set to 1
        return (callFlags & 2) != 0;
    }

    /// @notice Returns whether the address is a system contract.
    /// @param _address The address to test
    /// @return `true` or `false` based on whether the `_address` is a system contract.
    function isSystemContract(address _address) internal pure returns (bool) {
        return uint160(_address) <= uint160(MAX_SYSTEM_CONTRACT_ADDRESS);
    }

    /// @notice Method used for burning a certain amount of gas.
    /// @param _gasToPay The number of gas to burn.
    function burnGas(uint32 _gasToPay) internal view {
        bool precompileCallSuccess = unsafePrecompileCall(
            0, // The precompile parameters are formal ones. We only need the precompile call to burn gas.
            _gasToPay
        );
        require(precompileCallSuccess, "Failed to charge gas");
    }
}

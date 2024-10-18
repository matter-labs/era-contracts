// SPDX-License-Identifier: MIT

object "EvmGasManager" {
    code {
        return(0, 0)
    }
    object "EvmGasManager_deployed" {
        code {
            function ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT() -> addr {
                addr := 0x0000000000000000000000000000000000008002
            }

            function IS_ACCOUNT_EVM_PREFIX() -> prefix {   
                prefix :=  shl(255, 1)
            }

            function IS_ACCOUNT_WARM_PREFIX() -> prefix {
                prefix :=  shl(254, 1)
            }

            function IS_SLOT_WARM_PREFIX() -> prefix {
                prefix :=  shl(253, 1)
            }

            function PRECOMPILES_END() -> value {
                value := sub(0xffff, 1) // TODO should we exclude system contracts?
            }

            function EVM_GAS_SLOT() -> value {
                value := 4
            }

            function EVM_AUX_DATA_SLOT() -> value {
                value := 5
            }

            function EVM_ACTIVE_FRAME_FLAG() -> value {
                value := 2
            }

            function EVM_STATIC_FLAG() -> value {
                value := 1
            }

            function ADDRESS_MASK() -> mask {   
                mask :=  sub(shl(160, 1), 1)
            }

            function $llvm_AlwaysInline_llvm$__getRawSenderCodeHash() -> hash {
                mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
                mstore(4, caller())
            
                let success := staticcall(gas(), ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 0, 36, 0, 0)
            
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
                
                returndatacopy(0, 0, 32)
                hash := mload(0)
            }

            /// @dev Checks that the call is done by the EVM emulator in system mode.
            function $llvm_AlwaysInline_llvm$_onlyEvmSystemCall() {
                let callFlags := verbatim_0i_1o("get_global::call_flags")
                let notSystemCall := iszero(and(callFlags, 2))

                if notSystemCall {
                    revert(0, 0) // TODO errors?
                }

                // SELFDESTRUCT is not supported, so it is ok to cache here
                let transientSlot := or(IS_ACCOUNT_EVM_PREFIX(), caller())
                let isEVM := tload(transientSlot)
                if iszero(isEVM) {
                    let versionedCodeHash := $llvm_AlwaysInline_llvm$__getRawSenderCodeHash()
                    isEVM := eq(shr(248, versionedCodeHash), 2)

                    if iszero(isEVM) {
                        revert(0, 0)
                    }

                    // we will not cache contract if it is being constructed
                    let isContractConstructed := iszero(and(0xFF, shr(240, versionedCodeHash)))
                    if isContractConstructed {
                        tstore(transientSlot, 1)
                    }
                }             
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let _calldata0Slot := calldataload(0)

            // Please note that we do not use the standard solidity calldata encoding here. 
            // This allows us to optimize the contract and reduce overhead.
            // We use 1 byte as selector, arguments can be packed, the size of the returned data may vary.
            let functionSelector := shr(248, _calldata0Slot)
            switch functionSelector
            case 0 { // function warmAccount(address account)
                // Warm account, if needed. If it is already warm, will return 32 bytes of unspecified data.
                // Account address should be packed in one 32-bytes word with selector.
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall()

                let account := and(ADDRESS_MASK(), _calldata0Slot)

                let wasWarm := true

                if gt(account, PRECOMPILES_END()) {
                    let transientSlot := or(IS_ACCOUNT_WARM_PREFIX(), account)
                    wasWarm := tload(transientSlot)

                    if iszero(wasWarm) {
                        tstore(transientSlot, 1)
                    }
                }

                if wasWarm {
                    return(0x0, 0x20)
                }
                return(0x0, 0x0)
            }
            case 1 { // function isSlotWarm(uint256 _slot)
                // If specified slot in the caller storage is warm, will return 32 bytes of unspecified data.
                mstore(0, calldataload(1)) // load _slot
                mstore(32, or(IS_SLOT_WARM_PREFIX(), caller())) // prefixed caller address

                let transientSlot := keccak256(0, 64)
    
                if tload(transientSlot) {
                    return(0x0, 0x20)
                }
                return(0x0, 0x0)
            }
            case 2 { // function warmSlot(uint256 _slot, uint256 currentValue)
                // Warm slot in caller storage, if needed. Will return original value of the slot if it is already warm.
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall()

                mstore(0, calldataload(1)) // load _slot
                mstore(32, or(IS_SLOT_WARM_PREFIX(), caller())) // prefixed caller address

                let transientSlot := keccak256(0, 64)
                let isWarm := tload(transientSlot)

                if isWarm {
                    let originalValue := tload(add(transientSlot, 1))
                    mstore(0x0, originalValue)
                    return(0x0, 0x20)
                }

                let currentValue := calldataload(33)
                tstore(transientSlot, 1)
                tstore(add(transientSlot, 1), currentValue)
                return(0x0, 0x0)
            }
            case 3 { // function pushEVMFrame(bool isStatic, uint256 passGas)
                // Save EVM frame context data
                // This method is used by EvmEmulator to save new frame context data for external call.
                // isStatic flag should be packed in one 32-bytes word with selector.
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall()
                let isStatic := and(_calldata0Slot, 1)
                let passGas := calldataload(32)
                tstore(EVM_GAS_SLOT(), passGas)
                tstore(EVM_AUX_DATA_SLOT(), or(isStatic, EVM_ACTIVE_FRAME_FLAG())) // mark frame as active
                return(0x0, 0x0)
            }
            case 4 { // function consumeEvmFrame()
                // This method is used by EvmEmulator to get context data.
                // If the frame is active, 32 bytes of unspecified data will be returned.
                // If the frame is active and is static, 64 bytes of unspecified data will be returned.
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall()

                let auxData := tload(EVM_AUX_DATA_SLOT())

                let isFrameActive := and(auxData, EVM_ACTIVE_FRAME_FLAG())
                if isFrameActive {
                    tstore(EVM_AUX_DATA_SLOT(), 0) // mark as consumed

                    let passGas := tload(EVM_GAS_SLOT())
                    mstore(0x0, passGas)

                    let isStatic := and(auxData, EVM_STATIC_FLAG())
                    if isStatic {
                        return(0x0, 0x40)
                    }
                    return(0x0, 0x20)
                }

                // We do not have active frame. This means that the EVM contract was called from the EraVM contract.
                // We should mark the EVM contract as warm.
                let isSenderWarmSlot := or(IS_ACCOUNT_WARM_PREFIX(), caller())
                tstore(isSenderWarmSlot, 1)
                return(0x0, 0x0)
            }
            default {
                revert(0, 0)
            }
        }
    }
}

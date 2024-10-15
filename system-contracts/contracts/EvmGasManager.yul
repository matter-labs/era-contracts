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
                value := sub(0xffff, 1) // TODO system contracts?
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

            function $llvm_AlwaysInline_llvm$__getRawCodeHash(account) -> hash {
                mstore(0, 0x4DE2E46800000000000000000000000000000000000000000000000000000000)
                mstore(4, account)
            
                let success := staticcall(gas(), ACCOUNT_CODE_STORAGE_SYSTEM_CONTRACT(), 0, 36, 0, 0)
            
                if iszero(success) {
                    // This error should never happen
                    revert(0, 0)
                }
                
                returndatacopy(0, 0, 32)
                hash := mload(0)
            }

            function $llvm_AlwaysInline_llvm$_onlyEvmSystemCall(sender) {
                let callFlags := verbatim_0i_1o("get_global::call_flags")
                let notSystemCall := iszero(and(callFlags, 2))

                if notSystemCall {
                    revert(0, 0)
                }

                let transientSlot := or(IS_ACCOUNT_EVM_PREFIX(), sender)
                let isEVM := tload(transientSlot)
                if iszero(isEVM) {
                    let versionedCodeHash := $llvm_AlwaysInline_llvm$__getRawCodeHash(sender)
                    isEVM := eq(shr(248, versionedCodeHash), 2)

                    if iszero(isEVM) {
                        revert(0, 0)
                    }

                    let isContractConstructed := iszero(and(0xFF, shr(240, versionedCodeHash)))
                    if isContractConstructed {
                        tstore(transientSlot, 1)
                    }
                }             
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////
            
            let _sender := caller()

            let _calldata0Slot := calldataload(0)

            let functionSelector := shr(248, _calldata0Slot)
            switch functionSelector
            case 0 { // function warmAccount(address account)
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall(_sender)

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
                mstore(0, calldataload(1))
                mstore(32, or(IS_SLOT_WARM_PREFIX(), _sender))

                let transientSlot := keccak256(0, 64)
    
                if tload(transientSlot) {
                    return(0x0, 0x20)
                }
                return(0x0, 0x0)
            }
            case 2 { // function warmSlot(uint256 _slot, uint256 _currentValue)
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall(_sender)

                mstore(0, calldataload(1))
                mstore(32, or(IS_SLOT_WARM_PREFIX(), _sender))

                let transientSlot := keccak256(0, 64)
                let isWarm := tload(transientSlot)

                if isWarm {
                    let originalValue := tload(add(transientSlot, 1))
                    mstore(0x0, originalValue)
                    return(0x0, 0x20)
                }

                let value := calldataload(33)
                tstore(transientSlot, 1)
                tstore(add(transientSlot, 1), value)
                return(0x0, 0x0)
            }
            case 3 { // function pushEVMFrame(bool isStatic, uint256 passGas)
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall(_sender)
                let isStatic := and(_calldata0Slot, 1)
                let passGas := calldataload(32)
                tstore(EVM_GAS_SLOT(), passGas)
                tstore(EVM_AUX_DATA_SLOT(), or(isStatic, EVM_ACTIVE_FRAME_FLAG()))
                return(0x0, 0x0)
            }
            case 4 { // function consumeEvmFrame()
                $llvm_AlwaysInline_llvm$_onlyEvmSystemCall(_sender)

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

                let isSenderWarmSlot := or(IS_ACCOUNT_WARM_PREFIX(), _sender)
                tstore(isSenderWarmSlot, 1)
                return(0x0, 0x0)
            }
            default {
                revert(0, 0)
            }
        }
    }
}

object "EvmEmulator" {
    code {
        function MAX_POSSIBLE_ACTIVE_BYTECODE() -> max {
            max := MAX_POSSIBLE_INIT_BYTECODE_LEN()
        }

        /// @dev This function is used to get the initCode.
        /// @dev It assumes that the initCode has been passed via the calldata and so we use the pointer
        /// to obtain the bytecode.
        function getConstructorBytecode() {
            loadCalldataIntoActivePtr()

            let size := getActivePtrDataSize()

            if gt(size, MAX_POSSIBLE_INIT_BYTECODE_LEN()) {
                panic()
            }

            mstore(BYTECODE_LEN_OFFSET(), size)
        }

        function padBytecode(offset, len) -> blobLen {
            let trueLastByte := add(offset, len)

            // clearing out additional bytes
            mstore(trueLastByte, 0)
            mstore(add(trueLastByte, 32), 0)

            blobLen := len

            if mod(blobLen, 32) {
                blobLen := add(blobLen, sub(32, mod(blobLen, 32)))
            }

            // Now it is divisible by 32, but we must make sure that the number of 32 byte words is odd
            if iszero(mod(blobLen, 64)) {
                blobLen := add(blobLen, 32)
            }
        }

        function validateBytecodeAndChargeGas(offset, deployedCodeLen, gasToReturn) -> returnGas {
            if deployedCodeLen {
                // EIP-3860
                if gt(deployedCodeLen, MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()) {
                    panic()
                }

                // EIP-3541
                let firstByte := shr(248, mload(offset))
                if eq(firstByte, 0xEF) {
                    panic()
                }
            }

            let gasForCode := mul(deployedCodeLen, 200)
            returnGas := chargeGas(gasToReturn, gasForCode)
        }

        <!-- @include EvmEmulatorFunctions.template.yul -->

        <!-- @include calldata-opcodes/ConstructorScope.template.yul -->

        function simulate(
            isCallerEVM,
            evmGasLeft,
            isStatic,
        ) -> returnOffset, returnLen, retGasLeft {

            returnOffset := MEM_OFFSET()
            returnLen := 0

            <!-- @include EvmEmulatorLoop.template.yul -->

            retGasLeft := evmGasLeft
        }

        ////////////////////////////////////////////////////////////////
        //                      FALLBACK
        ////////////////////////////////////////////////////////////////

        let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

        if isStatic {
            abortEvmEnvironment() // should never happen
        }

        getConstructorBytecode()

        if iszero(isCallerEVM) {
            evmGasLeft := getEvmGasFromContext()
            // Charge additional creation cost
            evmGasLeft := chargeGas(evmGasLeft, 32000)
        }

        let offset, len, gasToReturn := simulate(isCallerEVM, evmGasLeft, false)

        gasToReturn := validateBytecodeAndChargeGas(offset, len, gasToReturn)

        let blobLen := padBytecode(offset, len)

        mstore(add(offset, blobLen), len)
        mstore(add(offset, add(32, blobLen)), gasToReturn)

        verbatim_2i_0o("return_deployed", offset, add(blobLen, 64))
    }
    object "EvmEmulator_deployed" {
        code {
            function MAX_POSSIBLE_ACTIVE_BYTECODE() -> max {
                max := MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()
            }

            function getDeployedBytecode(rawCodeHash) {
                let success := $llvm_AlwaysInline_llvm$_fetchBytecodeByHash(rawCodeHash)
                let codeLen := and(shr(224, rawCodeHash), 0xffff)

                loadReturndataIntoActivePtr()

                mstore(BYTECODE_LEN_OFFSET(), codeLen)
            }

            <!-- @include EvmEmulatorFunctions.template.yul -->

            function simulate(
                isCallerEVM,
                evmGasLeft,
                isStatic,
            ) -> returnOffset, returnLen {

                returnOffset := MEM_OFFSET()
                returnLen := 0

                <!-- @include EvmEmulatorLoop.template.yul -->

                <!-- @include calldata-opcodes/RuntimeScope.template.yul -->

                if isCallerEVM {
                    // Includes gas
                    returnOffset := sub(returnOffset, 32)
                    checkOverflow(returnLen, 32)
                    returnLen := add(returnLen, 32)

                    mstore(returnOffset, evmGasLeft)
                }
            }

            function $llvm_Cold_llvm$_delegate7702(
                delegationAddress,
            ) -> success, returnOffset, returnLen {
                returnOffset := MEM_OFFSET()
                // Here fat pointers are used to perform a delegete call by reference,
                // so that calldata is not copied to memory.
                loadCalldataIntoActivePtr()
                // Get far call ABI:
                // gas = gas()
                // forwardingMode = 1 (ForwardFatPointer)
                // isConstructor = 0
                // isSystem = 0
                let farCallABI := or(shl(192, gas()), shl(224, 1))
                // Pack ABI into the pointer, since delegate call does not have
                // additional parameters for these values
                ptrPackIntoActive(farCallABI)
                // Perform the delegate call by reference to the 7702-delegated address
                success := verbatim_3i_1o("raw_delegate_call_byref", delegationAddress, 0, 0)
                returnLen := returndatasize()
                returndatacopy(returnOffset, 0, returnLen)
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let rawCodeHash := getRawCodeHash(getCodeAddress())
            let delegationAddr := delegationAddress(rawCodeHash)
            if gt(delegationAddr, 0) {
                // We process 7702 delegation before opening an EVM frame,
                // since we don't actually perform simulation here.
                // If this code is invoked from EVM interpreter, caller will
                // know how to handle the result, we're only acting as a proxy.
                let success, returnOffset, returnLen := $llvm_Cold_llvm$_delegate7702(delegationAddr)
                switch success
                    case 1 {
                        return(returnOffset, returnLen)
                    }
                    default {
                        revert(returnOffset, returnLen)
                    }
            }

            let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

            if iszero(isCallerEVM) {
                evmGasLeft := getEvmGasFromContext()
                isStatic := getIsStaticFromCallFlags()
            }

            // First, copy the contract's bytecode to be executed into the `BYTECODE_OFFSET`
            // segment of memory.
            getDeployedBytecode(rawCodeHash)

            let returnOffset, returnLen := simulate(isCallerEVM, evmGasLeft, isStatic)
            return(returnOffset, returnLen)
        }
    }
}

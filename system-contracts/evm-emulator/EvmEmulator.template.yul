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
            mstore(EMPTY_CODE_OFFSET(), 0)
            copyActivePtrData(BYTECODE_OFFSET(), 0, size)
        }

        function padBytecode(offset, len) -> blobOffset, blobLen {
            blobOffset := sub(offset, 32)
            let trueLastByte := add(offset, len)

            mstore(blobOffset, len)
            // clearing out additional bytes
            mstore(trueLastByte, 0)
            mstore(add(trueLastByte, 32), 0)

            blobLen := add(len, 32)

            if iszero(eq(mod(blobLen, 32), 0)) {
                blobLen := add(blobLen, sub(32, mod(blobLen, 32)))
            }

            // Now it is divisible by 32, but we must make sure that the number of 32 byte words is odd
            if iszero(eq(mod(blobLen, 64), 32)) {
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

        pop($llvm_AlwaysInline_llvm$_warmAddress(address()))
        
        let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

        if isStatic {
            revert(0, 0)
        }

        getConstructorBytecode()

        if iszero(isCallerEVM) {
            evmGasLeft := getEvmGasFromContext()
        }

        let offset, len, gasToReturn := simulate(isCallerEVM, evmGasLeft, false)

        gasToReturn := validateBytecodeAndChargeGas(offset, len, gasToReturn)

        offset, len := padBytecode(offset, len)

        mstore(add(offset, len), gasToReturn)

        verbatim_2i_0o("return_deployed", offset, add(len, 32))
    }
    object "EvmEmulator_deployed" {
        code {
            function MAX_POSSIBLE_ACTIVE_BYTECODE() -> max {
                max := MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()
            }

            function getDeployedBytecode() {
                let codeLen := fetchDeployedCode(
                    getCodeAddress(), 
                    BYTECODE_OFFSET(), // destination offset
                    0, // source offset
                    MAX_POSSIBLE_DEPLOYED_BYTECODE_LEN()
                )
            
                mstore(EMPTY_CODE_OFFSET(), 0)
                mstore(BYTECODE_LEN_OFFSET(), codeLen)
            }

            <!-- @include EvmEmulatorFunctions.template.yul -->

            function $llvm_NoInline_llvm$_simulate(
                isCallerEVM,
                evmGasLeft,
                isStatic,
            ) -> returnOffset, returnLen {

                returnOffset := MEM_OFFSET()
                returnLen := 0

                <!-- @include EvmEmulatorLoop.template.yul -->

                if eq(isCallerEVM, 1) {
                    // Includes gas
                    returnOffset := sub(returnOffset, 32)
                    checkOverflow(returnLen, 32)
                    returnLen := add(returnLen, 32)

                    mstore(returnOffset, evmGasLeft)
                }
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let evmGasLeft, isStatic, isCallerEVM := consumeEvmFrame()

            if iszero(isCallerEVM) {
                evmGasLeft := getEvmGasFromContext()
                isStatic := getIsStaticFromCallFlags()
            }

            // First, copy the contract's bytecode to be executed into the `BYTECODE_OFFSET`
            // segment of memory.
            getDeployedBytecode()

            let returnOffset, returnLen := $llvm_NoInline_llvm$_simulate(isCallerEVM, evmGasLeft, isStatic)
            return(returnOffset, returnLen)
        }
    }
}

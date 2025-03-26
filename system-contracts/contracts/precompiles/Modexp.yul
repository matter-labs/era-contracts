object "Modexp" {
    code {
        return(0, 0)
    }
    object "Modexp_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The gas cost of processing modexp circuit precompile.
            function MODEXP_GAS_COST() -> ret {
                // Current geometry is cycles_per_modexp_circuit: 25
                // so 80'000 / 25 == 3200
                ret := 3200
            }

            /// @dev The maximum amount of bytes for base.
            /// @dev This restriction comes from circuit precompile call limitations.
            function MAX_BASE_BYTES_SUPPORTED() -> ret {
                ret := 32 // 256 bits
            }

            /// @dev The maximum amount of bytes for exponent.
            /// @dev This restriction comes from circuit precompile call limitations.
            function MAX_EXP_BYTES_SUPPORTED() -> ret{
                ret := 32 // 256 bits
            }

            /// @dev The maximum amount of bytes for modulus.
            /// @dev This restriction comes from circuit precompile call limitations.
            function MAX_MOD_BYTES_SUPPORTED() -> ret{
                ret := 32 // 256 bits
            }

            //////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            //////////////////////////////////////////////////////////////////

            // @dev Packs precompile parameters into one word.
            // Note: functions expect to work with 32/64 bits unsigned integers.
            // Caller should ensure the type matching before!
            function unsafePackPrecompileParams(
                uint32_inputOffsetInWords,
                uint32_inputLengthInWords,
                uint32_outputOffsetInWords,
                uint32_outputLengthInWords,
                uint64_perPrecompileInterpreted
            ) -> rawParams {
                rawParams := uint32_inputOffsetInWords
                rawParams := or(rawParams, shl(32, uint32_inputLengthInWords))
                rawParams := or(rawParams, shl(64, uint32_outputOffsetInWords))
                rawParams := or(rawParams, shl(96, uint32_outputLengthInWords))
                rawParams := or(rawParams, shl(192, uint64_perPrecompileInterpreted))
            }

            /// @dev Executes the `precompileCall` opcode.
            function precompileCall(precompileParams, gasToBurn) -> ret {
                // Compiler simulation for calling `precompileCall` opcode
                ret := verbatim_2i_1o("precompile", precompileParams, gasToBurn)
            }

            /// @notice Burns remaining gas until revert.
            /// @dev This function is used to burn gas in the case of a failed precompile call.
            function burnGas() {
                // Precompiles that do not have a circuit counterpart
                // will burn the provided gas by calling this function.
                precompileCall(0, gas())
            }

            ////////////////////////////////////////////////////////////////
            //                      FALLBACK
            ////////////////////////////////////////////////////////////////

            let baseLen := calldataload(0)
            let expLen := calldataload(32)
            let modLen := calldataload(64)

            // Ensure base, exponent and modulus are less than maximum supported size.
            if gt(baseLen, MAX_BASE_BYTES_SUPPORTED()) {
                burnGas()
            }
            if gt(expLen, MAX_EXP_BYTES_SUPPORTED()) {
                burnGas()
            }
            if gt(modLen, MAX_MOD_BYTES_SUPPORTED()) {
                burnGas()
            }

            // Circuit input in-memory is following:
            // 1. baseLen bytes of base padded from left with (MAX_BASE_BYTES_SUPPORTED - baseLen) zeros.
            // 2. expLen bytes of exponent padded from left with (MAX_EXP_BYTES_SUPPORTED - expLen) zeros.
            // 3. modLen bytes of modulus padded from left with (MAX_MOD_BYTES_SUPPORTED - modLen) zeros.

            let precompileInputBytes := add(add(MAX_BASE_BYTES_SUPPORTED(), MAX_EXP_BYTES_SUPPORTED()), MAX_MOD_BYTES_SUPPORTED())

            // Copy input base, exp and mod from calldata to memory
            calldatacopy(sub(MAX_BASE_BYTES_SUPPORTED(), baseLen), 96, baseLen)
            calldatacopy(sub(add(MAX_EXP_BYTES_SUPPORTED(), MAX_BASE_BYTES_SUPPORTED()), expLen), add(96, baseLen), expLen)
            calldatacopy(sub(add(add(MAX_EXP_BYTES_SUPPORTED(), MAX_BASE_BYTES_SUPPORTED()), MAX_MOD_BYTES_SUPPORTED()), modLen), add(add(96, baseLen), expLen), modLen)

            let precompileParams := unsafePackPrecompileParams(
                0,                                  // input offset in words
                div(precompileInputBytes, 32),      // input length in words
                0,                                  // output offset in words
                div(MAX_MOD_BYTES_SUPPORTED(), 32), // output length in words
                0                                   // circuit doesn't check this value
            )

            let gasToPay := MODEXP_GAS_COST()
            let success := precompileCall(precompileParams, gasToPay)
            if iszero(success) {
                revert(0, 0)
            }

            // To achieve homogeneity of the circuit, we always return the max supported bytes of the modulus (e.g. 256).
            // It is assumed to be right-padded with zeros, thus we simply cut the modLen part to conform the specification.
            // See: https://eips.ethereum.org/EIPS/eip-198.
            return(sub(32, modLen), modLen)
        }
    }
}

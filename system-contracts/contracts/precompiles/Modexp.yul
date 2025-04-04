// SPDX-License-Identifier: MIT

object "Modexp" {
    code {
        return(0, 0)
    }
    object "Modexp_deployed" {
        code {
            ////////////////////////////////////////////////////////////////
            //                      CONSTANTS
            ////////////////////////////////////////////////////////////////

            /// @dev The gas cost for this precompile is computed as:
            ///      BASE_CIRCUIT_GAS / cycles_per_<precompile>_circuit
            ///
            /// @notice `BASE_CIRCUIT_GAS` is a protocol-level constant set to 80_000.
            ///         This value represents the gas allocated per full ZK circuit iteration.
            ///         It is used to align gas costs of precompiles with circuit constraints
            ///         in the ZKSync VM (ZK-friendly execution model).
            ///
            /// @note The division factor (e.g. 15, 25) is derived from the number of cycles
            ///       needed to execute one instance of the corresponding precompile in the circuit.
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

            /// @dev Packs precompile parameters into one word.
            /// Note: functions expect to work with 32/64 bits unsigned integers.
            /// Caller should ensure the type matching before!
            ///
            /// @notice The layout is as follows (from least to most significant bits):
            /// - [0..32)    uint32_inputOffsetInWords
            /// - [32..64)   uint32_inputLengthInWords
            /// - [64..96)   uint32_outputOffsetInWords
            /// - [96..128)  uint32_outputLengthInWords
            /// - [128..192) Reserved (e.g. memoryPageToRead / memoryPageToWrite) — currently unused and left as 0
            /// - [192..256) uint64_perPrecompileInterpreted (left-aligned in the 256-bit word)
            ///
            /// All fields except the last are packed contiguously into the lower 128 bits.
            /// The final `uint64_perPrecompileInterpreted` is left-aligned (i.e., stored in the top 64 bits),
            /// as memoryPageToRead and memoryPageToWrite are assumed to be zero and not used.
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
                // memoryPageToRead and memoryPageToWrite left as zero (bits 128..192)
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
            for { let i := 0 } lt(i, precompileInputBytes) { i := add(i, 32) } {
                mstore(i, 0)
            }

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
            // It is assumed to be left-padded with zeros, thus we simply cut the modLen part to conform the specification.
            // See: https://eips.ethereum.org/EIPS/eip-198.
            return(sub(32, modLen), modLen)
        }
    }
}

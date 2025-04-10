// SPDX-License-Identifier: MIT

object "EcMul" {
    code {
        return(0, 0)
    }
    object "EcMul_deployed" {
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
            function ECMUL_GAS_COST() -> ret {
                // Currently geometry is set to cycles_per_ecmul_circuit: 15,
                // so 80'000 / 15 == 5334
                ret := 5334
            }

            // ////////////////////////////////////////////////////////////////
            //                      HELPER FUNCTIONS
            // ////////////////////////////////////////////////////////////////

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

            // Copy x1, y1, scalar (3 x 32 bytes) from calldata to memory
            calldatacopy(0, 0, 96)

            // We conduct all validations inside the precompileCall
            let precompileParams := unsafePackPrecompileParams(
                0, // input offset in words
                3, // input length in words (x, y, scalar)
                0, // output offset in words
                3, // output length in words success, (x, y)
                0  // No special meaning, ecmul circuit doesn't check this value
            )
            let gasToPay := ECMUL_GAS_COST()

            let success := precompileCall(precompileParams, gasToPay)
            let internalSuccess := mload(0)

            switch and(success, internalSuccess)
            case 0 {
                revert(0, 0)
            }
            default {
                return(32, 64)
            }
        }
    }
}

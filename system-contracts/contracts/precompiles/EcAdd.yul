// SPDX-License-Identifier: MIT

object "EcAdd" {
    code {
        return(0, 0)
    }
    object "EcAdd_deployed" {
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
            function ECADD_GAS_COST() -> ret {
                // Current geometry: cycles_per_ecadd_circuit: 812,
                // so 80'000 / 812 == 98
                ret := 98
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

            // Copy x1, y1, x2, y2 (4 x 32 bytes) from calldata to memory
            calldatacopy(0, 0, 128)

            // We conduct all validations inside the precompileCall

            let precompileParams := unsafePackPrecompileParams(
                0, // input offset in words
                4, // input length in words (x1, y1, x2, y2)
                0, // output offset in words
                3, // output length in words success, (x, y)
                0  // No special meaning, ecadd circuit doesn't check this value
            )
            let gasToPay := ECADD_GAS_COST()

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
